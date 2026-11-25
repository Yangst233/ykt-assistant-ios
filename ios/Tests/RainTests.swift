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
