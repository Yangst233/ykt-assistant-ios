import Foundation
import Security

struct Account: Codable, Identifiable {
    let service: Service
    let userID: String
    let name: String
    var cookieProperties: Data
    var lessons: [String: Lesson] = [:]
    var id: String { service.rawValue + ":" + userID }

    static func forLaunch(_ accounts: [Account], service: Service?, selectedID: String?) -> Account? {
        if let matching = accounts.first(where: { $0.id == selectedID && (service == nil || $0.service == service) }) {
            return matching
        }
        // Older versions saved accounts but no active selection. New logins were appended.
        return service == nil ? accounts.last : nil
    }
}

enum Vault {
    static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.ykt.assistant.ios",
        kSecAttrAccount as String: "accounts"
    ]

    static func read() throws -> [Account] {
        var request = query
        request[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = result as? Data else { throw RainError.keychain(status) }
        return try JSONDecoder().decode([Account].self, from: data)
    }

    static func write(_ accounts: [Account]) throws {
        let data = try JSONEncoder().encode(accounts)
        let values = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw RainError.keychain(status) }
    }

    static func encodeCookies(_ cookies: [HTTPCookie]) throws -> Data {
        let properties = cookies.compactMap { $0.properties }.map {
            Dictionary(uniqueKeysWithValues: $0.map { ($0.key.rawValue, $0.value) })
        }
        return try PropertyListSerialization.data(fromPropertyList: properties, format: .binary, options: 0)
    }

    static func decodeCookies(_ data: Data) throws -> [HTTPCookie] {
        guard let properties = try PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]] else {
            throw RainError.invalid("Cookie")
        }
        return properties.compactMap {
            HTTPCookie(properties: Dictionary(uniqueKeysWithValues: $0.map { (HTTPCookiePropertyKey($0.key), $0.value) }))
        }
    }
}
