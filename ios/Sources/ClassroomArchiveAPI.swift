import Foundation
import ImageIO
import UIKit

extension RainAPI {
    func historicalSlides(lessonID: String, presentationID: String) async throws -> (JSON, [JSON]) {
        let data = try await request("/api/v3/classroom-report/student/ppt", query: [
            .init(name: "lesson_id", value: lessonID), .init(name: "presentationId", value: presentationID)
        ]).0.object("data")
        if data["lessonId"] != nil && data.field("lessonId") != lessonID { throw RainError.invalid("课件课堂关联") }
        if data["presentationId"] != nil && data.field("presentationId") != presentationID { throw RainError.invalid("课件关联") }
        return (data, try data.rows("slideList").filter {
            ["1", "true"].contains($0.field("visible").lowercased())
        })
    }

    func uploadAnswerImage(_ bytes: Data) async throws -> String {
        guard bytes.count <= 16 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(bytes as CFData, nil) else {
            throw RainError.invalid("图片无法读取或超过 16 MB")
        }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: 2048,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let bitmap = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw RainError.invalid("答案图片")
        }
        let size = CGSize(width: CGFloat(bitmap.width), height: CGFloat(bitmap.height))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let jpeg = UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.8) { context in
            let rect = CGRect(origin: .zero, size: size)
            context.cgContext.setFillColor(UIColor.white.cgColor)
            context.cgContext.fill(rect)
            UIImage(cgImage: bitmap).draw(in: rect)
        }
        guard !jpeg.isEmpty, jpeg.count <= 4 * 1024 * 1024 else { throw RainError.invalid("压缩后图片超过 4 MB") }
        let response = try await request("/pc/generate_qiniu_token",
                                         body: ["bucket_name": "cms-attachment", "expired_time": 3600]).0
        let token = try response.object("data").field("token")
        guard response["success"] as? Bool == true, !token.isEmpty else { throw RainError.invalid("未取得图片上传凭证") }
        let key = "\(Int64(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString).jpg"
        let boundary = UUID().uuidString
        let endpoint = URL(string: "https://upload.qiniup.com/")!
        var upload = URLRequest(url: endpoint)
        upload.httpMethod = "POST"
        upload.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        upload.setValue("application/json", forHTTPHeaderField: "Accept")
        var body = Data()
        for (field, value) in [("token", token), ("key", key), ("fname", key)] {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(key)\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8))
        body.append(jpeg)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, reply) = try await session.upload(for: upload, from: body)
        guard let reply = reply as? HTTPURLResponse, (200..<300).contains(reply.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? JSON,
              json.field("key") == key, json["success"] == nil || json["success"] as? Bool == true else {
            throw RainError.invalid("图片上传未确认成功")
        }
        return "https://qn-scd1.yuketang.cn/" + key
    }
}
