import SwiftUI

@MainActor
struct LiveSlideView: View {
    let api: RainAPI
    let lesson: Lesson
    let presentation: String
    let page: String
    @State private var slides: [[String]]?
    @State private var loadError: String?
    @State private var retry = 0

    var body: some View {
        Group {
            if let loadError {
                VStack(alignment: .leading, spacing: 8) {
                    Text(loadError).foregroundStyle(.secondary)
                    Button("重试") { retry += 1 }
                }
            } else if let slides {
                if let number = Int(page), number > 0, slides.indices.contains(number - 1) {
                    LiveSlideImage(api: api, page: number, urls: slides[number - 1])
                        .id(number)
                } else {
                    Text(page.isEmpty ? "等待教师发送放映页码" : "当前放映页无法预览")
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView("正在载入放映课件")
            }
        }
        .task(id: retry) {
            do {
                loadError = nil
                let rows = try await api.liveSlides(presentation: presentation, lesson: lesson)
                try Task.checkCancellation()
                slides = rows.map { row in
                    ["cover", "coverAlt", "thumbnail"].map(row.field).filter { !$0.isEmpty }
                }
            } catch {
                if !Task.isCancelled { loadError = error.localizedDescription }
            }
        }
    }
}

@MainActor
private struct LiveSlideImage: View {
    let api: RainAPI
    let page: Int
    let urls: [String]
    @State private var image: UIImage?
    @State private var loadError: String?
    @State private var retry = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
                    .accessibilityLabel("教师正在放映的课件")
            } else if let loadError {
                Text(loadError).foregroundStyle(.secondary)
                Button("重试当前页") { retry += 1 }
            } else {
                ProgressView("正在载入当前页")
            }
            Text("第 \(page) 页").font(.caption).foregroundStyle(.secondary)
        }
        .task(id: retry) {
            do {
                loadError = nil
                let bytes = try await api.slideImage(urls)
                try Task.checkCancellation()
                guard let picture = UIImage(data: bytes) else { throw RainError.invalid("课件图片") }
                image = picture
            } catch {
                if !Task.isCancelled { loadError = error.localizedDescription }
            }
        }
    }
}
