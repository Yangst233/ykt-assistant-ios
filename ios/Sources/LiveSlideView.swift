import SwiftUI

@MainActor
struct LiveSlideView: View {
    let api: RainAPI
    let lesson: Lesson
    let presentation: String
    let page: Int?
    let open: (Deck) -> Void
    @State private var deck: Deck?
    @State private var loadError: String?
    @State private var retry = 0

    var body: some View {
        Group {
            if let deck {
                Button {
                    var selected = deck
                    selected.live = .init(lessonID: lesson.id, presentationID: presentation, initialPage: page)
                    open(selected)
                } label: {
                    VStack(spacing: 0) {
                        if let index = deck.index(for: page), let page {
                            LiveSlideImage(api: api, page: page, urls: deck.slides[index])
                                .id(page)
                        } else {
                            Label(page == nil ? "等待教师开始放映" : "当前放映页无法预览", systemImage: "slides")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 110)
                        }
                        HStack {
                            Text(deck.title).font(.subheadline.weight(.medium)).appTextStyle(.contentTitle).lineLimit(2)
                            Spacer()
                            Text("查看实时课件")
                                .font(.caption)
                                .foregroundStyle(.tint).appTextStyle(.action)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 12)
                    }
                    .foregroundStyle(.primary)
                    .standaloneContainer(cornerRadius: 20)
                    .contentShape(RoundedRectangle(cornerRadius: 20))
                }
                .buttonStyle(.plain)
                .accessibilityHint("打开实时课件阅读器")
            } else if let loadError {
                VStack(alignment: .leading, spacing: 8) {
                    Text(loadError).foregroundStyle(.secondary)
                    Button("重试") { retry += 1 }
                }
                .padding()
            } else {
                ProgressView("正在载入放映课件").padding()
            }
        }
        .task(id: retry) {
            do {
                loadError = nil
                let value = try await api.liveDeck(presentation: presentation, lesson: lesson, page: page)
                try Task.checkCancellation()
                deck = value
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
    @State private var failed = false

    var body: some View {
        VStack(spacing: 0) {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("教师正在放映的课件")
            } else {
                Color(uiColor: .tertiarySystemGroupedBackground)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .overlay {
                        if failed {
                            Label("封面暂不可用", systemImage: "photo").foregroundStyle(.secondary)
                        } else {
                            ProgressView()
                        }
                    }
            }
            Text("第 \(page) 页")
                .font(.subheadline.monospacedDigit()).appTextStyle(.detail)
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
        }
        .task {
            do {
                let bytes = try await api.slideImage(urls)
                try Task.checkCancellation()
                guard let picture = UIImage(data: bytes) else { throw RainError.invalid("课件图片") }
                image = picture
            } catch {
                if !Task.isCancelled { failed = true }
            }
        }
    }
}
