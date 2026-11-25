import XCTest
@testable import RainAssistant

private final class MockHTTP: URLProtocol {
    static var respond: ((URLRequest) throws -> (Int, [String: String], Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.respond)
            let (status, headers, data) = try handler(request)
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status,
                                                         httpVersion: "HTTP/1.1", headerFields: headers))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
}

final class RainTests: XCTestCase {
    @MainActor private func client() -> RainAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockHTTP.self]
        return RainAPI(service: .changjiang, configuration: configuration)
    }

    @MainActor func testCheckInUsesUpstreamContract() async throws {
        let api = client()
        api.userID = "89"
        MockHTTP.respond = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://changjiang.yuketang.cn/api/v3/lesson/checkin")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-uid"), "89")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (200, ["set-auth": "Bearer local-test"], Data(#"{"code":0,"data":{"lessonToken":"ws-test"}}"#.utf8))
        }
        defer { MockHTTP.respond = nil }
        let lesson = try await api.checkIn("123")
        XCTAssertEqual(lesson.id, "123")
        XCTAssertEqual(lesson.bearer, "local-test")
        XCTAssertEqual(lesson.token, "ws-test")
    }

    @MainActor func testBusinessFailureIsNotHTTPFailure() async throws {
        let api = client()
        MockHTTP.respond = { _ in (200, [:], Data(#"{"code":50070}"#.utf8)) }
        defer { MockHTTP.respond = nil }
        do {
            _ = try await api.checkIn("123")
            XCTFail("Expected business error")
        } catch RainError.business(50070, _) {}
    }

    @MainActor func testScanRejectsCrossServiceAndDuplicateID() async throws {
        let api = client()
        let id = try await api.lessonID("https://changjiang.yuketang.cn/v/lesson/?lesson_id=123")
        XCTAssertEqual(id, "123")
        for input in [
            "https://pro.yuketang.cn/v/lesson/?lesson_id=123",
            "https://changjiang.yuketang.cn/v/lesson/?lesson_id=123&lessonId=456"
        ] {
            do { _ = try await api.lessonID(input); XCTFail("Expected invalid QR") }
            catch RainError.invalid(_) {}
        }
    }

    @MainActor func testQRUsesFreshRequestAndSameSessionForAuthorization() async throws {
        let api = client()
        MockHTTP.respond = { request in
            switch request.url?.path {
            case "/api/v3/user/login/pre-info":
                XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
                XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-cache")
                return (200, ["Set-Cookie": "sessionid=local-qr; Path=/; Secure"],
                        Data(#"{"code":0,"data":{"token":"local-qr-token"}}"#.utf8))
            case "/api/v3/user/login":
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "sessionid"), "local-qr")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "sessionid=local-qr")
                return (200, [:], Data(#"{"code":50001}"#.utf8))
            default:
                XCTFail("Unexpected QR request")
                return (404, [:], Data())
            }
        }
        defer { MockHTTP.respond = nil }
        let qr = try await api.request("/api/v3/user/login/pre-info").0.object("data")
        do {
            _ = try await api.request("/api/v3/user/login", body: ["token": qr.field("token")])
            XCTFail("Expected expired QR")
        } catch RainError.business(50001, _) {}
    }

    func testColdLaunchRestoresSavedSelectionAcrossServices() {
        let standard = Account(service: .standard, userID: "12", name: "", cookieProperties: Data())
        let pro = Account(service: .pro, userID: "12", name: "", cookieProperties: Data())
        let accounts = [standard, pro]
        XCTAssertEqual(Account.forLaunch(accounts, service: .standard, selectedID: standard.id)?.id, standard.id)
        XCTAssertEqual(Account.forLaunch(accounts, service: nil, selectedID: nil)?.id, pro.id)
        XCTAssertEqual(Account.forLaunch(accounts, service: .standard, selectedID: pro.id)?.service, .pro)
        XCTAssertNil(Account.forLaunch(accounts, service: .pro, selectedID: nil))
        XCTAssertNil(Account.forLaunch([standard], service: .pro, selectedID: pro.id))
    }

    @MainActor func testQuestionTimelineReplayAndManualSubmissionContracts() throws {
        let model = QuizModel()
        let item: JSON = ["type": "problem", "pres": "72", "prob": "13", "dt": 12345]
        model.ingest(["op": "hello", "timeline": [item]], presentation: "")
        let original = try XCTUnwrap(model.question("13"))
        model.update("13", round: original.round) {
            $0.specification = ["problemType": 2, "options": [["key": "B"], ["key": "A"]]]
            $0.draft.options = ["A", "B"]
        }
        model.ingest(["op": "hello", "timeline": [item]], presentation: "")
        let q = try XCTUnwrap(model.question("13"))
        XCTAssertEqual(q.round, original.round)
        XCTAssertEqual(q.presentation, "72")
        let now = ContinuousClock().now
        let answer = try q.submission(finished: false, wall: 54321, now: now)
        XCTAssertEqual(answer.path, "/api/v3/lesson/problem/answer")
        XCTAssertEqual(answer.body.field("dt"), "54321")
        XCTAssertEqual(answer.body["result"] as? [String], ["B", "A"])
        let retry = try q.submission(finished: true, wall: 54321, now: now)
        XCTAssertEqual(retry.path, "/api/v3/lesson/problem/retry")
        let entry = try XCTUnwrap((retry.body["problems"] as? [JSON])?.first)
        XCTAssertEqual(entry.field("dt"), "12345")
        XCTAssertTrue(entry["retry_times"] is NSNull)
    }

    func testAIRequiresMatchingNonceAndExistingOption() throws {
        let q = ClassroomQuestion(id: "8", presentation: "42", eventTime: 0,
            specification: ["problemType": 1, "options": [["key": "A"]]])
        let valid = #"{"schema_version":1,"question_token":"local","problem_type":1,"status":"answered","answer":{"option_keys":["A"],"blank_values":[],"text":""},"explanation":"Reason","confidence":0.8}"#
        XCTAssertEqual(try QuizAI.parse(valid, question: q, nonce: "local").draft.options, ["A"])
        XCTAssertThrowsError(try QuizAI.parse(valid, question: q, nonce: "different"))
        XCTAssertThrowsError(try QuizAI.parse(valid.replacingOccurrences(of: "[\"A\"]", with: "[\"Z\"]"), question: q, nonce: "local"))
    }

    @MainActor func testLiveDeckKeepsUpstreamTitleAndUsesOneBasedTeacherPage() async throws {
        let api = client()
        MockHTTP.respond = { request in
            XCTAssertEqual(request.url?.path, "/api/v3/lesson/presentation/fetch")
            XCTAssertEqual(request.url?.query, "presentation_id=72")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer local-test")
            let response = #"{"code":0,"data":{"id":"72","title":"第一讲","slides":[{"cover":"https://example.com/1"},{"cover":"https://example.com/2"}]}}"#
            return (200, [:], Data(response.utf8))
        }
        defer { MockHTTP.respond = nil }
        let lesson = Lesson(id: "123", bearer: "local-test", token: "local-ws", created: Date())
        let deck = try await api.liveDeck(presentation: "72", lesson: lesson, page: 2)
        XCTAssertEqual(deck.title, "第一讲")
        XCTAssertEqual(deck.live?.lessonID, "123")
        XCTAssertEqual(deck.index(for: deck.live?.initialPage), 1)
        XCTAssertNil(deck.index(for: 0))
        XCTAssertNil(deck.index(for: 3))
    }

    @MainActor func testAttendanceReportUsesAccountSessionAndRejectsDifferentLesson() async throws {
        let api = client()
        MockHTTP.respond = { request in
            XCTAssertEqual(request.url?.path, "/api/v3/classroom-report/student/detail")
            XCTAssertTrue(request.url?.query?.contains("lesson_id=123") == true)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (200, [:], Data(#"{"code":0,"data":{"lessonId":"456","detail":{}}}"#.utf8))
        }
        defer { MockHTTP.respond = nil }
        do {
            _ = try await api.classroomReport(.detail, lessonID: "123")
            XCTFail("Expected mismatched lesson to be rejected")
        } catch RainError.invalid(_) {}
    }

    func testPPTXNameUsesOneExtensionAndFitsFileComponent() {
        XCTAssertEqual(DeckExport.fileStem("  课程：第一讲.PPTX ", fallback: "Slides"), "课程：第一讲")
        XCTAssertEqual(DeckExport.fileStem("讲义/第一讲", fallback: "Slides"), "讲义_第一讲")
        XCTAssertEqual(DeckExport.fileStem(" .pptx ", fallback: "文档"), "文档")
        XCTAssertLessThanOrEqual(DeckExport.fileStem(String(repeating: "讲", count: 200), fallback: "Slides").utf8.count, 180)
    }

    func testCookieRoundTrip() throws {
        let properties: [HTTPCookiePropertyKey: Any] = [
            .name: "sessionid", .value: "test-value", .domain: "www.yuketang.cn", .path: "/", .secure: "TRUE"
        ]
        let original = try XCTUnwrap(HTTPCookie(properties: properties))
        let restored = try XCTUnwrap(Vault.decodeCookies(Vault.encodeCookies([original])).first)
        XCTAssertEqual(restored.name, original.name)
        XCTAssertEqual(restored.value, original.value)
        XCTAssertEqual(restored.domain, original.domain)
        XCTAssertEqual(restored.isSecure, original.isSecure)
    }
}
