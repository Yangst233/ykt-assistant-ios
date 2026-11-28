import SwiftUI

@MainActor
final class OfflineDownloadQueue: ObservableObject {
    enum Status: Equatable {
        case queued, downloading, cancelling, saved, cancelled, failed(String)
    }

    struct Entry: Identifiable {
        let id: UUID
        let account: String
        let title: String
        let total: Int
        var page = 0
        var status: Status = .queued
    }

    private struct Request {
        let deck: Deck
        let api: RainAPI
        let sourceKey: String
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var libraryRevision = 0
    private var requests: [UUID: Request] = [:]
    private var active: UUID?
    private var worker: Task<Void, Never>?

    @discardableResult
    func enqueue(deck: Deck, api: RainAPI, automatic: Bool = false) -> String {
        guard !api.userID.isEmpty, deck.localPages == nil, !deck.slides.isEmpty else {
            return "当前课件无法加入下载列表"
        }
        let account = api.service.rawValue + ":" + api.userID
        let sourceKey = deck.offlineSourceKey
        let alreadyQueued = entries.contains { entry in
            guard entry.account == account, requests[entry.id]?.sourceKey == sourceKey else { return false }
            return automatic || entry.status == .queued || entry.status == .downloading || entry.status == .cancelling
        }
        guard !alreadyQueued else { return "此课件已在下载列表中" }
        if automatic, let directory = try? OfflineStorage.directory(account),
           OfflineStorage.decks(directory).contains(where: { $0.sourceKey == sourceKey }) {
            return "此课件已保存至离线课件库"
        }
        let id = UUID()
        requests[id] = Request(deck: deck, api: api, sourceKey: sourceKey)
        entries.append(Entry(id: id, account: account, title: deck.title, total: deck.slides.count))
        startNext()
        return "已加入下载列表，可继续阅读课件"
    }

    func cancel(_ id: UUID) {
        guard let index = index(for: id) else { return }
        switch entries[index].status {
        case .queued:
            entries[index].status = .cancelled
        case .downloading:
            entries[index].status = .cancelling
            worker?.cancel()
        default: break
        }
    }

    func retry(_ id: UUID) {
        guard let index = index(for: id), requests[id] != nil else { return }
        switch entries[index].status {
        case .failed, .cancelled:
            entries[index].status = .queued
            entries[index].page = 0
            startNext()
        default: break
        }
    }

    func remove(_ id: UUID) {
        guard let index = index(for: id) else { return }
        switch entries[index].status {
        case .saved, .failed, .cancelled:
            entries.remove(at: index)
            requests[id] = nil
        default: break
        }
    }

    private func index(for id: UUID) -> Int? { entries.firstIndex { $0.id == id } }

    private func startNext() {
        guard active == nil, let next = entries.first(where: { $0.status == .queued }),
              let request = requests[next.id], let nextIndex = index(for: next.id) else { return }
        let id = next.id
        active = id
        entries[nextIndex].page = 1
        entries[nextIndex].status = .downloading
        worker = Task {
            let status: Status
            do {
                let directory = try OfflineStorage.directory(next.account)
                try await OfflineStorage.download(request.deck, api: request.api, into: directory) { page in
                    if let index = self.index(for: id), self.entries[index].status == .downloading {
                        self.entries[index].page = page
                    }
                }
                status = .saved
                libraryRevision += 1
                requests[id] = nil
            } catch {
                status = Task.isCancelled ? .cancelled : .failed(error.localizedDescription)
            }
            if let index = index(for: id) { entries[index].status = status }
            worker = nil
            active = nil
            startNext()
        }
    }
}
