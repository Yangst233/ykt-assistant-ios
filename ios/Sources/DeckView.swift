import SwiftUI
import Photos
import CryptoKit

@MainActor
struct DeckView: View {
    let deck: Deck
    let api: RainAPI
    var followTeacher: Binding<Bool>? = nil
    var teacherPage: Int? = nil
    var followError: String? = nil
    var retryFollow: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appearance: AppAppearance
    @StateObject private var preloadStore = PPTPreloadStore()
    @State private var index = 0
    @State private var image: UIImage?
    @State private var error: String?
    @EnvironmentObject private var exports: CoursewareExport
    @State private var automaticShare: ExportShare?
    @State private var pendingPPTX: (deck: Deck, name: String)?
    @State private var exportName = ""
    @State private var namingDeck: Deck?
    @State private var retry = 0
    @State private var saved = false
    @State private var zoom = 1.0

    var body: some View {
        NavigationStack {
            GeometryReader { bounds in
                let landscape = bounds.size.width > bounds.size.height
                VStack {
                    if landscape {
                        landscapeViewport
                    } else {
                        slideViewport
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        if let followTeacher {
                            Toggle("跟随老师", isOn: followTeacher).padding(.horizontal)
                        }
                        pageControls
                    }
                    if followTeacher != nil, let followError {
                        Text(followError).font(.footnote).foregroundStyle(.secondary)
                        Button("重试同步") { retryFollow?() }
                    }
                    if exports.running {
                        ExportProgressView(export: exports).padding(.horizontal)
                    }
                    if let file = exports.file {
                        ShareLink(item: file) { Label("分享导出文件", systemImage: "square.and.arrow.up") }
                    }
                    if let exportError = exports.error {
                        Text(exportError).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { FrostedReaderBackground() }
            .navigationTitle(deck.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu("操作", systemImage: "ellipsis.circle") {
                        Button("保存当前图片", systemImage: "photo") { save() }.disabled(image == nil || exports.running)
                        Button("导出 PPTX", systemImage: "document") { preparePPTX() }.disabled(exports.running)
                        Button("导出 ZIP", systemImage: "archivebox") { exports.start(deck, api: api, pptx: false, name: nil) }.disabled(exports.running)
                        Button("重新载入当前页", systemImage: "arrow.clockwise") {
                            if let key = slideCacheKey {
                                appearance.removeCachedPPTImage(key)
                                preloadStore.remove(key)
                            }
                            retry += 1
                        }
                    }
                }
            }
            .onChange(of: deck.id, initial: true) { _, _ in
                index = deck.index(for: teacherPage ?? deck.live?.initialPage) ?? 0
            }
            .onChange(of: teacherPage) { _, page in
                if followTeacher?.wrappedValue == true, let target = deck.index(for: page) { index = target }
            }
            .task(id: "\(deck.id):\(index):\(retry)") {
                zoom = 1
                let current = index
                guard let key = cacheKey(for: current) else { image = nil; return }
                if let cached = cachedPage(key) {
                    image = cached
                    await preloadPages(after: current)
                    return
                }
                image = nil
                let urls = deck.slides[current]
                do {
                    let data = try await api.slideImage(urls)
                    try Task.checkCancellation()
                    guard let bitmap = UIImage(data: data) else { throw RainError.invalid("课件图片") }
                    appearance.cachePPTImage(bitmap, key: key)
                    if appearance.cachePPT && appearance.pptPreload == .entire { preloadStore.store(data, key: key) }
                    image = bitmap
                    await preloadPages(after: current)
                } catch {
                    if !Task.isCancelled { self.error = error.localizedDescription }
                }
            }
            .onChange(of: exports.file) { _, file in
                if let file { automaticShare = ExportShare(file: file) }
            }
            .sheet(isPresented: Binding(get: { namingDeck != nil }, set: { if !$0 { namingDeck = nil } }),
                   onDismiss: {
                       guard let pendingPPTX else { return }
                       self.pendingPPTX = nil
                       exports.start(pendingPPTX.deck, api: api, pptx: true, name: pendingPPTX.name)
                   }) {
                NavigationStack {
                    MaterialForm {
                        LabeledContent("重命名") {
                            TextField("输入 PPTX 文件名", text: $exportName)
                                .multilineTextAlignment(.trailing)
                                .accessibilityLabel("重命名")
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background { FrostedReaderBackground() }
                    .navigationTitle("导出 PPTX")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("取消") { namingDeck = nil } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("导出") {
                                guard let source = namingDeck else { return }
                                pendingPPTX = (source, exportName)
                                namingDeck = nil
                            }
                        }
                    }
                }
                .presentationDetents([.medium])
            }
            .sheet(item: $automaticShare) { request in
                ExportActivitySheet(file: request.file)
            }
            .alert("图片已保存", isPresented: $saved) { Button("好") {} }
            .alert("课件", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好") { error = nil }
            } message: { Text(error ?? "") }
        }
    }

    private var slideCacheKey: String? { cacheKey(for: index) }

    private func cacheKey(for page: Int) -> String? {
        guard deck.slides.indices.contains(page) else { return nil }
        return ([api.service.rawValue, api.userID] + deck.slides[page]).joined(separator: "\n")
    }

    private func cachedPage(_ key: String) -> UIImage? {
        guard appearance.cachePPT else { return nil }
        if let cached = appearance.cachedPPTImage(key) { return cached }
        guard let image = preloadStore.image(key) else { return nil }
        appearance.cachePPTImage(image, key: key)
        return image
    }

    private func preloadPages(after page: Int) async {
        guard appearance.cachePPT else { return }
        let ranges = appearance.pptPreload.pages(after: page, total: deck.slides.count)
        for range in ranges {
            for next in range {
                guard appearance.cachePPT, !Task.isCancelled else { return }
                guard let key = cacheKey(for: next),
                      !preloadStore.contains(key) else { continue }
                if let cached = appearance.cachedPPTImage(key),
                   let data = cached.pngData() {
                    preloadStore.store(data, key: key)
                    continue
                }
                guard let data = try? await api.slideImage(deck.slides[next]), !Task.isCancelled,
                      appearance.cachePPT, let bitmap = UIImage(data: data) else { continue }
                preloadStore.store(data, key: key)
                appearance.cachePPTImage(bitmap, key: key)
            }
        }
    }

    private var slideViewport: some View {
        GeometryReader { geometry in
            if zoom > 1, let image {
                ScrollView([.horizontal, .vertical]) {
                    slideImage(image)
                        .frame(width: geometry.size.width * zoom, height: geometry.size.height * zoom)
                }
                .onTapGesture(count: 2) { zoom = 1 }
            } else {
                ZStack {
                    Color.clear
                    if let image {
                        slideImage(image)
                            .onTapGesture(count: 2) { zoom = 2 }
                    } else {
                        ProgressView()
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .contentShape(Rectangle())
                .simultaneousGesture(DragGesture(minimumDistance: 24).onEnded { gesture in
                    let movement = gesture.translation
                    guard abs(movement.width) >= 44, abs(movement.width) > abs(movement.height) else { return }
                    movePage(by: movement.width < 0 ? 1 : -1)
                })
            }
        }
    }

    private func slideImage(_ image: UIImage) -> some View {
        Image(uiImage: image).resizable().scaledToFit()
            .accessibilityLabel("课件第 \(index + 1) 页")
    }

    private func movePage(by offset: Int) {
        guard followTeacher?.wrappedValue != true, deck.slides.indices.contains(index + offset) else { return }
        index += offset
    }

    private var landscapeViewport: some View {
        slideViewport
            .padding(.horizontal, 56)
            .overlay(alignment: .leading) {
                landscapePageButton("上一页", icon: "chevron.left", offset: -1)
                    .padding(.leading, 8)
            }
            .overlay(alignment: .trailing) {
                landscapePageButton("下一页", icon: "chevron.right", offset: 1)
                    .padding(.trailing, 8)
            }
            .overlay(alignment: .bottomLeading) {
                pageCount.padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .padding(8)
            }
            .overlay(alignment: .bottomTrailing) {
                if let followTeacher {
                    Toggle("跟随老师", isOn: followTeacher)
                        .fixedSize()
                        .controlSize(.small)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                        .padding(8)
                }
            }
    }

    @ViewBuilder private func landscapePageButton(_ title: String, icon: String, offset: Int) -> some View {
        if #available(iOS 26.0, *) {
            pageButton(title, icon: icon, offset: offset)
                .glassEffect(.regular.interactive(), in: .circle)
        } else {
            pageButton(title, icon: icon, offset: offset)
                .background(.regularMaterial, in: Circle())
        }
    }

    @ViewBuilder private var pageControls: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 16) {
                HStack(spacing: 12) {
                    pageButton("上一页", icon: "chevron.left", offset: -1)
                        .glassEffect(.regular.interactive(), in: .circle)
                    pageCount
                    pageButton("下一页", icon: "chevron.right", offset: 1)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
            }
            .padding()
        } else {
            HStack(spacing: 12) {
                pageButton("上一页", icon: "chevron.left", offset: -1)
                pageCount
                pageButton("下一页", icon: "chevron.right", offset: 1)
            }
            .padding()
        }
    }

    private var pageCount: some View {
        Text("\(index + 1) / \(deck.slides.count)")
            .font(.footnote.monospacedDigit())
            .foregroundStyle(.secondary)
            .accessibilityLabel("第 \(index + 1) 页，共 \(deck.slides.count) 页")
    }

    private func pageButton(_ title: String, icon: String, offset: Int) -> some View {
        Button {
            movePage(by: offset)
        } label: {
            Label(title, systemImage: icon)
                .labelStyle(.iconOnly)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .disabled(followTeacher?.wrappedValue == true || !deck.slides.indices.contains(index + offset))
    }

    private func preparePPTX() {
        exportName = DeckExport.fileStem(deck.title, fallback: "Slides")
        namingDeck = deck
    }

    private func save() {
        guard let image else { return }
        Task {
            do {
                let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
                guard status == .authorized || status == .limited else {
                    throw RainError.invalid("请在系统设置中允许添加照片")
                }
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                }
                saved = true
            } catch { self.error = error.localizedDescription }
        }
    }
}


struct FrostedReaderBackground: View {
    @EnvironmentObject private var appearance: AppAppearance

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(uiColor: .systemBackground)
                if let wallpaper = appearance.wallpaper {
                    Image(uiImage: wallpaper)
                        .resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                    Color(uiColor: .systemBackground).opacity(appearance.wallpaperOverlayOpacity)
                }
                Rectangle().fill(.regularMaterial)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

}

private final class PPTPreloadStore: ObservableObject {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)

    deinit { try? FileManager.default.removeItem(at: root) }

    func contains(_ key: String) -> Bool {
        FileManager.default.fileExists(atPath: file(key).path)
    }

    func image(_ key: String) -> UIImage? { UIImage(contentsOfFile: file(key).path) }

    func remove(_ key: String) { try? FileManager.default.removeItem(at: file(key)) }

    func store(_ data: Data, key: String) {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try data.write(to: file(key), options: [.atomic, .completeFileProtection])
        } catch {
            // The reader still works when there is no room for preloaded pages.
        }
    }

    private func file(_ key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(digest)
    }
}

private struct ExportShare: Identifiable {
    let file: URL
    var id: URL { file }
}

private struct ExportActivitySheet: UIViewControllerRepresentable {
    let file: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [file], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

@MainActor
struct LiveDeckReader: View {
    @ObservedObject var model: AppModel
    let api: RainAPI
    @State private var deck: Deck
    @State private var error: String?
    @State private var retry = 0
    @AppStorage("followTeacher") private var followTeacher = false

    init(model: AppModel, api: RainAPI, initialDeck: Deck) {
        self.model = model
        self.api = api
        _deck = State(initialValue: initialDeck)
    }

    private var targetPresentation: String? {
        guard followTeacher, !model.isLessonFinished,
              model.lesson?.id == deck.live?.lessonID, !model.presentation.isEmpty else { return nil }
        return model.presentation
    }

    var body: some View {
        let target = targetPresentation
        let page = target == deck.live?.presentationID ? Int(model.livePage) : nil
        DeckView(deck: deck, api: api, followTeacher: $followTeacher, teacherPage: page,
                 followError: followTeacher ? error : nil, retryFollow: { retry += 1 })
            .task(id: FollowRequest(presentation: target, retry: retry)) {
                error = nil
                guard let target, target != deck.live?.presentationID, let lesson = model.lesson else { return }
                do {
                    let updated = try await api.liveDeck(presentation: target, lesson: lesson, page: nil)
                    try Task.checkCancellation()
                    guard target == targetPresentation, lesson.id == model.lesson?.id else { return }
                    deck = updated
                } catch {
                    if !Task.isCancelled { self.error = error.localizedDescription }
                }
            }
    }

    private struct FollowRequest: Equatable {
        let presentation: String?
        let retry: Int
    }
}
