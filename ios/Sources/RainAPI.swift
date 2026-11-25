import Foundation
import UIKit

typealias JSON = [String: Any]

extension Dictionary where Key == String, Value == Any {
    func field(_ key: String) -> String {
        if let value = self[key] as? String { return value }
        return (self[key] as? NSNumber)?.stringValue ?? ""
    }
    func object(_ key: String) throws -> JSON {
        guard let value = self[key] as? JSON else { throw RainError.invalid(key) }
        return value
    }
    func rows(_ key: String) throws -> [JSON] {
        guard let value = self[key] as? [JSON] else { throw RainError.invalid(key) }
        return value
    }
}

enum RainError: LocalizedError {
    case invalid(String), http(Int), business(Int, String), keychain(Int32)
    var errorDescription: String? {
        switch self {
        case .invalid(let name): return "雨课堂数据无效或缺失：\(name)"
        case .http(401): return "登录或课堂凭证已失效"
        case .http(403): return "没有访问权限"
        case .http(let code): return "网络请求失败（HTTP \(code)）"
        case .business(50001, _): return "二维码已超时，请刷新"
        case .business(50070, _): return "此课堂需要动态二维码"
        case .business(51203, _): return "签到二维码已过期"
        case .business(let code, let message): return message.isEmpty ? "请求失败（\(code)）" : message
        case .keychain(let status): return "安全存储访问失败（\(status)）"
        }
    }
}

enum Service: String, CaseIterable, Codable, Identifiable {
    case standard = "www", pro, changjiang, huanghe
    var id: String { rawValue }
    var host: String { "\(rawValue).yuketang.cn" }
    var title: String {
        switch self {
        case .standard: return "雨课堂"
        case .pro: return "荷塘雨课堂"
        case .changjiang: return "长江雨课堂"
        case .huanghe: return "黄河雨课堂"
        }
    }
}

struct Lesson: Codable {
    let id: String
    let bearer: String
    let token: String
    let created: Date
}

final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
final class RainAPI {
    let service: Service
    let session: URLSession
    let media: URLSession
    var cookies: [HTTPCookie] = []
    var userID = ""

    init(service: Service, configuration: URLSessionConfiguration = .ephemeral) {
        self.service = service
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 65
        session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        let images = URLSessionConfiguration.ephemeral
        images.httpShouldSetCookies = false
        images.httpCookieStorage = nil
        images.urlCache = URLCache(memoryCapacity: 32 * 1024 * 1024, diskCapacity: 0)
        media = URLSession(configuration: images, delegate: NoRedirect(), delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
        media.invalidateAndCancel()
    }

    func headers(_ url: URL, authenticated: Bool = true) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("app", forHTTPHeaderField: "x-client")
        request.setValue("ykt", forHTTPHeaderField: "xtbz")
        request.setValue("1610", forHTTPHeaderField: "buildnumber")
        request.setValue("client=app&tag=1.3.3&platform=Android", forHTTPHeaderField: "xtua")
        request.setValue("Apple", forHTTPHeaderField: "brand")
        request.setValue(UIDevice.current.systemVersion, forHTTPHeaderField: "systemversion")
        request.setValue("true", forHTTPHeaderField: "isphysicaldevice")
        guard authenticated, url.host == service.host else { return request }
        let path = url.path.isEmpty ? "/" : url.path
        let active = cookies.filter {
            let domain = $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return ($0.expiresDate ?? .distantFuture) > Date()
                && (service.host == domain || service.host.hasSuffix("." + domain))
                && (path == $0.path || path.hasPrefix($0.path.hasSuffix("/") ? $0.path : $0.path + "/"))
        }
        for (name, value) in HTTPCookie.requestHeaderFields(with: active) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue(active.first { $0.name == "csrftoken" }?.value, forHTTPHeaderField: "x-csrftoken")
        request.setValue(active.first { $0.name == "sessionid" }?.value, forHTTPHeaderField: "sessionid")
        if !userID.isEmpty { request.setValue(userID, forHTTPHeaderField: "x-uid") }
        return request
    }

    func request(_ path: String, query: [URLQueryItem] = [], body: JSON? = nil,
                 bearer: String? = nil) async throws -> (JSON, HTTPURLResponse) {
        var target = URLComponents()
        target.scheme = "https"
        target.host = service.host
        target.path = path
        target.queryItems = query.isEmpty ? nil : query
        guard let url = target.url else { throw RainError.invalid("URL") }
        var request = headers(url)
        if path == "/api/v3/user/login/pre-info" {
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        }
        if let bearer { request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw RainError.invalid("HTTP") }
        guard (200..<300).contains(response.statusCode) else { throw RainError.http(response.statusCode) }
        let fields = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            if let name = pair.key as? String, let value = pair.value as? String { result[name] = value }
        }
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: fields, for: url) {
            cookies.removeAll { $0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path }
            if (cookie.expiresDate ?? .distantFuture) > Date() { cookies.append(cookie) }
        }
        guard data.count <= 16 * 1024 * 1024,
              let json = try JSONSerialization.jsonObject(with: data) as? JSON else {
            throw RainError.invalid("JSON")
        }
        let code = Int(json.field("code")) ?? 0
        if code != 0 { throw RainError.business(code, json.field("msg")) }
        return (json, response)
    }

    func profile() async throws -> JSON {
        let profile = try await request("/v/course_meta/user_info").0.object("data").object("user_profile")
        userID = profile.field("user_id")
        guard !userID.isEmpty else { throw RainError.invalid("user_id") }
        return profile
    }

    static func validLesson(_ id: String) -> Bool {
        id.range(of: "^[0-9]{1,20}$", options: .regularExpression) != nil && id.contains { $0 != "0" }
    }

    func lessonID(_ input: String) async throws -> String {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.validLesson(raw) { return raw }
        guard raw.utf8.count <= 8192, !raw.unicodeScalars.contains(where: { $0.value < 32 }),
              let url = URLComponents(string: raw), url.scheme == "https", url.host == service.host,
              url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              !["login", "authorize", "wechat"].contains(where: { url.path.contains($0) }) else {
            throw RainError.invalid("当前服务的课堂二维码")
        }
        if !url.path.hasPrefix("/api/v3/lesson/check-in/") {
            let ids = (url.queryItems ?? []).filter { ["lessonId", "lesson_id", "lessonid"].contains($0.name) }
            if !ids.isEmpty {
                guard ids.count == 1, let id = ids.first?.value, Self.validLesson(id) else {
                    throw RainError.invalid("课堂 ID")
                }
                return id
            }
            guard ["/v/lesson/", "/m/v2/lesson/", "/lesson/"].contains(where: { url.path.hasPrefix($0) }) else {
                throw RainError.invalid("课堂二维码")
            }
        }
        let id = try await request("/api/v3/app/scan", body: ["url": raw]).0.object("data").field("value")
        guard Self.validLesson(id) else { throw RainError.invalid("课堂 ID") }
        return id
    }

    func checkIn(_ id: String) async throws -> Lesson {
        let (json, response) = try await request("/api/v3/lesson/checkin",
            body: ["source": 21, "lessonId": id, "joinIfNotIn": true])
        let token = try json.object("data").field("lessonToken")
        let bearer = response.value(forHTTPHeaderField: "set-auth")?
            .replacingOccurrences(of: "(?i)^Bearer\\s+", with: "", options: .regularExpression) ?? ""
        guard !bearer.isEmpty, !token.isEmpty else { throw RainError.invalid("课堂凭证") }
        return Lesson(id: id, bearer: bearer, token: token, created: Date())
    }

    enum ReportPart: String {
        case info = "lesson-info"
        case detail
    }

    func classroomReport(_ part: ReportPart, lessonID: String) async throws -> JSON {
        guard Self.validLesson(lessonID) else { throw RainError.invalid("课堂 ID") }
        let query = [URLQueryItem(name: "lesson_id", value: lessonID),
                     URLQueryItem(name: "front_time", value: String(Int64(Date().timeIntervalSince1970 * 1000)))]
        let data = try await request("/api/v3/classroom-report/student/" + part.rawValue, query: query).0.object("data")
        guard data["lessonId"] == nil || data.field("lessonId") == lessonID else { throw RainError.invalid("课堂报告关联") }
        return data
    }

    func liveDeck(presentation: String, lesson: Lesson, page: Int?) async throws -> Deck {
        let data = try await request("/api/v3/lesson/presentation/fetch",
            query: [.init(name: "presentation_id", value: presentation)], bearer: lesson.bearer).0.object("data")
        guard data["id"] == nil || data.field("id") == presentation else { throw RainError.invalid("课件关联") }
        let slides = try Deck.slideImages(data.rows("slides"))
        guard !slides.isEmpty else { throw RainError.invalid("暂无可查看的课件页面") }
        let title = data.field("title").trimmingCharacters(in: .whitespacesAndNewlines)
        return Deck(title: title.isEmpty ? "实时课件" : title, slides: slides,
                    live: .init(lessonID: lesson.id, presentationID: presentation, initialPage: page))
    }

    func slideImage(_ candidates: [String]) async throws -> Data {
        var failure: Error = RainError.invalid("课件图片地址")
        for candidate in candidates {
            do { return try await image(candidate) }
            catch { try Task.checkCancellation(); failure = error }
        }
        throw failure
    }

    func image(_ raw: String, qr: Bool = false) async throws -> Data {
        if qr, raw.hasPrefix("data:image/"), raw.utf8.count <= 3 * 1024 * 1024,
           let comma = raw.firstIndex(of: ","), raw[..<comma].hasSuffix(";base64"),
           let data = Data(base64Encoded: String(raw[raw.index(after: comma)...])) { return data }
        let domains = ["yuketang.cn", "xuetangx.com", "qiniucdn.com", "clouddn.com", "qbox.me"]
            + (qr ? ["weixin.qq.com", "wx.qq.com"] : [])
        var target = URL(string: raw, relativeTo: URL(string: "https://" + service.host))
        for _ in 0..<4 {
            guard let url = target?.absoluteURL, url.scheme == "https", url.user == nil, url.password == nil,
                  url.port == nil || url.port == 443, let host = url.host,
                  domains.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else {
                throw RainError.invalid("图片地址")
            }
            var request = headers(url)
            request.setValue("image/*", forHTTPHeaderField: "Accept")
            if qr {
                request.cachePolicy = .reloadIgnoringLocalCacheData
                request.timeoutInterval = 8
            }
            let (bytes, response) = try await media.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw RainError.invalid("图片响应") }
            if (300..<400).contains(response.statusCode), let next = response.value(forHTTPHeaderField: "Location") {
                target = URL(string: next, relativeTo: url)
                continue
            }
            guard response.statusCode == 200 else { throw RainError.http(response.statusCode) }
            guard response.mimeType?.hasPrefix("image/") == true else { throw RainError.invalid("图片类型") }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 24 * 1024 * 1024 else { throw RainError.invalid("图片超过大小限制") }
                data.append(byte)
            }
            return data
        }
        throw RainError.invalid("图片重定向")
    }
}
