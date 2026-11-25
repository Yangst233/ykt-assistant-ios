import SwiftUI
import CoreImage.CIFilterBuiltins

struct Deck: Identifiable {
    let id = UUID()
    let title: String
    let slides: [[String]]
}

@MainActor
final class AppModel: ObservableObject {
    @Published var service = Service.standard
    @Published var accounts: [Account] = []
    @Published var selected: String?
    @Published var courses: [JSON] = []
    @Published var live: [JSON] = []
    @Published var feed: [JSON] = []
    @Published var report: JSON?
    @Published var qr: UIImage?
    @Published var loginStatus: String?
    @Published var error: String?
    @Published var pendingLesson: String?
    @Published var lesson: Lesson?
    @Published var connection = ""
    @Published var presentation = ""
    @Published var livePage = ""
    @Published var deck: Deck?
    @Published var busy = false
    @Published var canPage = true
    private var cursor: String?
    private var seenCursors = Set<String>()
    private var work: Task<Void, Never>?
    private var stream: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var foreground = true
    private var lessonFinished = false
    private var loginBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var generation = UUID()
    private(set) var api: RainAPI?

    init() {
        do { accounts = try Vault.read() }
        catch { self.error = error.localizedDescription }
    }

    func run(_ operation: @escaping @MainActor () async throws -> Void) {
        cancel()
        let current = generation
        busy = true
        work = Task {
            defer { if generation == current { busy = false } }
            do { try await operation() }
            catch {
                if generation == current && !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    func cancel() {
        endLoginBackgroundTask()
        qr = nil
        loginStatus = nil
        generation = UUID()
        work?.cancel()
        work = nil
        busy = false
    }

    func switchService(_ service: Service) {
        reset()
        self.service = service
        if let account = accounts.first(where: { $0.service == service }) { select(account) }
    }

    private func reset() {
        cancel()
        disconnect()
        api = nil
        selected = nil
        lesson = nil
        pendingLesson = nil
        presentation = ""
        livePage = ""
        qr = nil
        deck = nil
        report = nil
        courses = []
        live = []
        feed = []
        cursor = nil
        seenCursors = []
        canPage = true
    }

    func select(_ account: Account) {
        reset()
        service = account.service
        run {
            let api = RainAPI(service: account.service)
            api.cookies = try Vault.decodeCookies(account.cookieProperties)
            api.userID = account.userID
            self.api = api
            self.selected = account.id
            try await self.loadCourses()
        }
    }

    func delete(_ account: Account) {
        do {
            let remaining = accounts.filter { $0.id != account.id }
            try Vault.write(remaining)
            accounts = remaining
            if selected == account.id { reset() }
        } catch { self.error = error.localizedDescription }
    }

    func login() {
        run {
            defer {
                if !Task.isCancelled {
                    self.qr = nil
                    self.loginStatus = nil
                    self.endLoginBackgroundTask()
                }
            }
            while true {
                self.loginStatus = "正在获取登录二维码…"
                let api = RainAPI(service: self.service)
                let data = try await api.request("/api/v3/user/login/pre-info").0.object("data")
                let token = data.field("token")
                guard !token.isEmpty else { throw RainError.invalid("二维码 token") }
                let image = try await self.loginImage(data, api: api)
                try Task.checkCancellation()
                self.qr = image
                self.loginStatus = "请使用微信扫描并确认。"
                do {
                    _ = try await api.request("/api/v3/user/login", body: ["token": token])
                } catch RainError.business(50001, _) {
                    try Task.checkCancellation()
                    self.qr = nil
                    guard self.foreground else {
                        throw RainError.business(50001, "")
                    }
                    self.loginStatus = "旧二维码已过期，正在获取新码…"
                    try await Task.sleep(for: .seconds(1))
                    continue
                }
                try await self.finishLogin(api)
                return
            }
        }
    }

    private func loginImage(_ data: JSON, api: RainAPI) async throws -> UIImage {
        let address = data.field("qrImage").trimmingCharacters(in: .whitespacesAndNewlines)
        if !address.isEmpty {
            do {
                let bytes = try await api.image(address, qr: true)
                if let image = UIImage(data: bytes) { return image }
            } catch { try Task.checkCancellation() }
        }
        let content = data.field("qrContent").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { throw RainError.invalid("登录二维码图片") }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(content.utf8)
        guard let output = filter.outputImage?.transformed(by: .init(scaleX: 8, y: 8)),
              let bitmap = CIContext().createCGImage(output, from: output.extent) else {
            throw RainError.invalid("登录二维码图片")
        }
        return UIImage(cgImage: bitmap)
    }

    private func finishLogin(_ api: RainAPI) async throws {
        qr = nil
        loginStatus = "扫码已授权，正在获取账号信息…"
        let profile = try await api.profile()
        try Task.checkCancellation()
        var account = Account(service: api.service, userID: api.userID, name: profile.field("name"),
                              cookieProperties: try Vault.encodeCookies(api.cookies))
        account.lessons = accounts.first { $0.id == account.id }?.lessons ?? [:]
        let updated = accounts.filter { $0.id != account.id } + [account]
        try Vault.write(updated)
        accounts = updated
        select(account)
    }

    func loadCourses() async throws {
        guard let api else { return }
        let courses = try await api.request("/v/course_meta/learning_list/").0.rows("data")
        let live = try await api.request("/api/v3/classroom/on-lesson").0.object("data").rows("onLessonClassrooms")
        try Task.checkCancellation()
        self.courses = courses
        self.live = live
        try saveSession()
    }

    func saveSession(lesson: Lesson? = nil) throws {
        guard let api, let index = accounts.firstIndex(where: { $0.id == selected }) else { return }
        var updated = accounts
        updated[index].cookieProperties = try Vault.encodeCookies(api.cookies)
        updated[index].lessons = updated[index].lessons.filter { Date().timeIntervalSince($0.value.created) < 24 * 3600 }
        if let lesson { updated[index].lessons[lesson.id] = lesson }
        try Vault.write(updated)
        accounts = updated
    }

    func enter(_ input: String) {
        run {
            guard let api = self.api else { return }
            let id = try await api.lessonID(input)
            if let saved = self.accounts.first(where: { $0.id == self.selected })?.lessons[id],
               Date().timeIntervalSince(saved.created) < 24 * 3600 {
                self.open(saved)
            } else { self.pendingLesson = id }
        }
    }

    func confirm(_ id: String) {
        pendingLesson = nil
        run {
            guard let api = self.api else { return }
            let lesson = try await api.checkIn(id)
            try Task.checkCancellation()
            self.open(lesson)
            try self.saveSession(lesson: lesson)
        }
    }

    private func open(_ lesson: Lesson) {
        disconnect()
        self.lesson = lesson
        lessonFinished = false
        presentation = ""
        livePage = ""
        connect()
    }

    func leave() {
        cancel()
        guard let socket, let lesson else {
            disconnect()
            self.lesson = nil
            return
        }
        self.lesson = nil
        Task {
            if let data = try? JSONSerialization.data(withJSONObject: ["op": "leavelesson", "lessonid": lesson.id]) {
                try? await socket.send(.string(String(decoding: data, as: UTF8.self)))
            }
            if self.socket === socket { disconnect() }
        }
    }

    func phase(_ phase: ScenePhase) {
        foreground = phase != .background
        if foreground {
            endLoginBackgroundTask()
            connect()
        } else {
            if qr != nil && loginBackgroundTask == .invalid {
                loginBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Rain QR authorization") {
                    Task { @MainActor in self.cancel() }
                }
            }
            disconnect()
        }
    }

    private func endLoginBackgroundTask() {
        guard loginBackgroundTask != .invalid else { return }
        let task = loginBackgroundTask
        loginBackgroundTask = .invalid
        UIApplication.shared.endBackgroundTask(task)
    }

    private func disconnect() {
        stream?.cancel()
        stream = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        connection = ""
    }

    func connect() {
        guard foreground, !lessonFinished, socket == nil, let api, let lesson,
              let url = URL(string: "wss://\(api.service.host)/wsapp/") else { return }
        let ws = api.session.webSocketTask(with: api.headers(url))
        socket = ws
        connection = "正在连接"
        ws.maximumMessageSize = 16 * 1024 * 1024
        ws.resume()
        stream = Task {
            defer {
                ws.cancel(with: .goingAway, reason: nil)
                if socket === ws { socket = nil }
            }
            do {
                let hello = ["op": "hello", "userid": api.userID, "role": "student",
                             "auth": lesson.token, "lessonid": lesson.id]
                let encoded = try JSONSerialization.data(withJSONObject: hello)
                try await ws.send(.string(String(decoding: encoded, as: UTF8.self)))
                while !Task.isCancelled {
                    let message = try await ws.receive()
                    guard socket === ws, !Task.isCancelled else { return }
                    let data: Data
                    switch message {
                    case .string(let string): data = Data(string.utf8)
                    case .data(let bytes): data = bytes
                    @unknown default: continue
                    }
                    guard let event = (try? JSONSerialization.jsonObject(with: data)) as? JSON else { continue }
                    if ["401", "403"].contains(event.field("code")) {
                        invalidateCredentials(lesson.id)
                        return
                    }
                    if event.field("op") == "lessonfinished" || event.field("message") == "lesson finished" {
                        lessonFinished = true
                        connection = "课堂已结束"
                        return
                    }
                    if event.field("op") == "hello" { connection = "课堂已连接" }
                    let timeline = event["timeline"] as? [JSON]
                    let recent = timeline?.last { $0.field("type") == "slide" && !$0.field("pres").isEmpty }
                    let id = event.field("presentation")
                    if let recent, id.isEmpty || event.field("op") == "hello" {
                        presentation = recent.field("pres")
                        livePage = recent.field("si")
                    } else if !id.isEmpty { presentation = id }
                    if !event.field("slideindex").isEmpty { livePage = event.field("slideindex") }
                    if let slide = event["slide"] as? JSON, !slide.field("si").isEmpty { livePage = slide.field("si") }
                }
            } catch {
                if socket === ws && !Task.isCancelled {
                    if ws.closeCode == .policyViolation
                        || [401, 403].contains((ws.response as? HTTPURLResponse)?.statusCode ?? 0) {
                        invalidateCredentials(lesson.id)
                    } else {
                        connection = "连接中断：\(error.localizedDescription)"
                    }
                }
            }
        }
    }

    private func invalidateCredentials(_ id: String) {
        disconnect()
        lesson = nil
        presentation = ""
        livePage = ""
        do {
            if let index = accounts.firstIndex(where: { $0.id == selected }) {
                var updated = accounts
                updated[index].lessons.removeValue(forKey: id)
                try Vault.write(updated)
                accounts = updated
            }
            error = "课堂凭证已失效，请重新进入课堂"
        } catch { self.error = error.localizedDescription }
    }

    func loadFeed(reset: Bool) async throws {
        guard let api, reset || canPage else { return }
        var body: JSON = ["size": 10, "type": [], "beginTime": NSNull(), "endTime": NSNull()]
        if !reset, let cursor { body["searchAfter"] = cursor }
        let page = try await api.request("/api/v3/activities/received/", body: body).0.rows("data")
        try Task.checkCancellation()
        if reset { feed = []; seenCursors = [] }
        var keys = Set(feed.map(feedKey))
        feed += page.filter { keys.insert(feedKey($0)).inserted }
        cursor = page.last?.field("sort")
        canPage = cursor.map { !$0.isEmpty && seenCursors.insert($0).inserted } ?? false
        try saveSession()
    }

    private func feedKey(_ item: JSON) -> String {
        if item.field("coursewareType") == "14" { return "lesson:" + item.field("coursewareId") }
        return [item.field("id"), item.field("sort")].joined(separator: ":")
    }

    func loadReport(_ id: String) {
        report = nil
        run {
            guard let api = self.api, RainAPI.validLesson(id) else { throw RainError.invalid("课堂 ID") }
            let query = [URLQueryItem(name: "lesson_id", value: id),
                         URLQueryItem(name: "front_time", value: String(Int64(Date().timeIntervalSince1970 * 1000)))]
            let root = "/api/v3/classroom-report/student/"
            let info = try await api.request(root + "lesson-info", query: query).0.object("data")
            let detail = try await api.request(root + "detail", query: query).0.object("data")
            for value in [info, detail] where value["lessonId"] != nil && value.field("lessonId") != id {
                throw RainError.invalid("课堂报告关联")
            }
            try Task.checkCancellation()
            self.report = ["id": id, "info": info, "detail": detail]
        }
    }

    func openDeck(id: String, title: String, historical: String?) {
        run {
            guard let api = self.api, !id.isEmpty else { throw RainError.invalid("课件 ID") }
            let rows: [JSON]
            if let historical {
                let data = try await api.request("/api/v3/classroom-report/student/ppt", query: [
                    .init(name: "lesson_id", value: historical), .init(name: "presentationId", value: id)
                ]).0.object("data")
                if data["lessonId"] != nil && data.field("lessonId") != historical { throw RainError.invalid("课件课堂关联") }
                if data["presentationId"] != nil && data.field("presentationId") != id { throw RainError.invalid("课件关联") }
                rows = try data.rows("slideList").filter {
                    ["1", "true"].contains($0.field("visible").lowercased())
                }
            } else {
                guard let lesson = self.lesson else { throw RainError.invalid("课堂凭证") }
                do {
                    let data = try await api.request("/api/v3/lesson/presentation/fetch",
                        query: [.init(name: "presentation_id", value: id)], bearer: lesson.bearer).0.object("data")
                    if data["id"] != nil && data.field("id") != id { throw RainError.invalid("课件关联") }
                    rows = try data.rows("slides")
                } catch RainError.http(let code) where code == 401 || code == 403 {
                    try Task.checkCancellation()
                    self.invalidateCredentials(lesson.id)
                    return
                }
            }
            let slides = rows.map { row in
                ["cover", "coverAlt", "thumbnail"].map(row.field).filter { !$0.isEmpty }
            }
            guard !slides.isEmpty, slides.allSatisfy({ !$0.isEmpty }) else { throw RainError.invalid("暂无可查看的课件页面") }
            try Task.checkCancellation()
            self.deck = Deck(title: title, slides: slides)
        }
    }
}
