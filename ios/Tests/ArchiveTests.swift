import XCTest
@testable import RainAssistant

final class ArchiveTests: XCTestCase {
    func testPictureOnlySubmissionContainsOriginalAndThumbnailURL() throws {
        let url = "https://qn-scd1.yuketang.cn/sample.jpg"
        var question = ClassroomQuestion(id: "q", presentation: "p", eventTime: 100,
                                         specification: ["problemType": 5])
        question.draft.pictures = [url]
        let request = try question.submission(finished: false, wall: 200, now: ContinuousClock().now)
        let result = try XCTUnwrap(request.body["result"] as? JSON)
        let pictures = try XCTUnwrap(result["pics"] as? [[String: String]])
        XCTAssertEqual(pictures, [["pic": url, "thumb": url + "?imageView2/2/w/568"]])
        XCTAssertEqual(result["content"] as? String, "")
    }

    func testOfflineStorageKeepsAccountsSeparate() throws {
        let first = UUID().uuidString
        let second = UUID().uuidString
        let firstDirectory = try OfflineStorage.directory(first)
        let secondDirectory = try OfflineStorage.directory(second)
        defer {
            try? FileManager.default.removeItem(at: firstDirectory)
            try? FileManager.default.removeItem(at: secondDirectory)
        }
        try OfflineStorage.write(["cursor": "next"], name: "feed.json", account: first)
        XCTAssertEqual(OfflineStorage.read("feed.json", account: first)?["cursor"] as? String, "next")
        XCTAssertNil(OfflineStorage.read("feed.json", account: second))
    }
}
