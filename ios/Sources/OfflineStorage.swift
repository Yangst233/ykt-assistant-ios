import Foundation
import CryptoKit
import UIKit

enum OfflineStorage {
    static func key(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func directory(_ account: String) throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        var root = base.appendingPathComponent("Offline-v1", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try root.setResourceValues(values)
        let url = root.appendingPathComponent(key(account), isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func read(_ name: String, account: String) -> JSON? {
        guard let url = try? directory(account).appendingPathComponent(name),
              let bytes = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: bytes)) as? JSON
    }

    static func write(_ value: JSON, name: String, account: String) throws {
        let url = try directory(account).appendingPathComponent(name)
        try JSONSerialization.data(withJSONObject: value).write(to: url, options: [.atomic, .completeFileProtection])
    }

    struct SavedDeck: Codable, Identifiable {
        let id: UUID
        let title: String
        let count: Int
        let bytes: Int
        let date: Date
        let sourceKey: String?

        func deck(in directory: URL) -> Deck {
            let location = directory.appendingPathComponent(id.uuidString)
            return Deck(title: title, slides: Array(repeating: [], count: count),
                        localPages: (0..<count).map { location.appendingPathComponent("\($0).image") })
        }
    }

    static func decks(_ directory: URL) -> [SavedDeck] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return entries.compactMap { location in
            guard UUID(uuidString: location.lastPathComponent) != nil,
                  let data = try? Data(contentsOf: location.appendingPathComponent("deck.json")),
                  let record = try? JSONDecoder().decode(SavedDeck.self, from: data),
                  record.id.uuidString == location.lastPathComponent, record.count > 0 else { return nil }
            return record
        }.sorted { $0.date > $1.date }
    }

    static func download(_ deck: Deck, api: RainAPI, into directory: URL,
                         progress: @escaping @MainActor (Int) -> Void) async throws {
        guard !deck.slides.isEmpty else { throw RainError.invalid("课件没有页面") }
        let id = UUID()
        let temporary = directory.appendingPathComponent(".partial-" + id.uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        var bytes = 0
        for index in deck.slides.indices {
            try Task.checkCancellation()
            await progress(index + 1)
            let data = try await deck.pageData(index, api: api)
            guard UIImage(data: data) != nil else { throw RainError.invalid("课件图片") }
            try data.write(to: temporary.appendingPathComponent("\(index).image"), options: .completeFileProtection)
            bytes += data.count
        }
        let record = SavedDeck(id: id, title: deck.title, count: deck.slides.count, bytes: bytes, date: Date(),
                               sourceKey: deck.offlineSourceKey)
        try JSONEncoder().encode(record).write(to: temporary.appendingPathComponent("deck.json"), options: .completeFileProtection)
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: temporary, to: directory.appendingPathComponent(id.uuidString))
    }
}
