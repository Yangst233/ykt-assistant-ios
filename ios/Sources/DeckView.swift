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
    var classroomModel: AppModel? = nil
    @State private var showsDanmu = false
    @EnvironmentObject private var offlineDownloads: OfflineDownloadQueue
    @State private var downloadNotice: String?
    @State private var noticeID: UUID?
    @AppStorage("pptShowsScrollingDanmu") private var showsScrollingDanmu = true
    @AppStorage("danmuEnabled") private var danmuEnabled = true
    @AppStorage("automaticallySaveCourseware") private var automaticallySaveCourseware = false
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
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @GestureState private var pinchScale: CGFloat = 1
    @GestureState private var dragOffset: CGSize = .zero
    @State private var showsLandscapeControls = true

    var body: some View {
        NavigationStack {
            GeometryReader { bounds in
                let landscape = bounds.size.width > bounds.size.height
                Group {
                    if landscape {
                        landscapeViewport
                    } else {
                        VStack {
                            slideViewport()
                            portraitControls
                            readerStatus
                        }
                    }
                }
                .toolbar(landscape ? .hidden : .visible, for: .navigationBar)
            }
            .background { FrostedReaderBackground() }
            .appNavigationTitle(deck.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { readerMenu }
            }
            .onChange(of: deck.id, initial: true) { _, _ in
                index = deck.index(for: teacherPage ?? deck.live?.initialPage) ?? 0
            }
            .onChange(of: teacherPage) { _, page in
                if followTeacher?.wrappedValue == true, let target = deck.index(for: page) { index = target }
            }
            .task(id: "\(deck.id):\(automaticallySaveCourseware)") {
                guard automaticallySaveCourseware, deck.localPages == nil, !Task.isCancelled else { return }
                offlineDownloads.enqueue(deck: deck, api: api, automatic: true)
            }
            .task(id: "\(deck.id):\(index):\(retry)") {
                resetZoom()
                let current = index
                guard let key = cacheKey(for: current) else { image = nil; return }
                if let cached = cachedPage(key) {
                    image = cached
                    await preloadPages(after: current)
                    return
                }
                image = nil
                do {
                    let data = try await deck.pageData(current, api: api)
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
                    .appNavigationTitle("导出 PPTX")
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
            .sheet(isPresented: $showsDanmu) {
                if let classroomModel {
                    NavigationStack {
                        ClassroomDanmuView(model: classroomModel, danmu: classroomModel.danmu)
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) { Button("关闭") { showsDanmu = false } }
                            }
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if let downloadNotice {
                    Text(downloadNotice)
                        .font(.subheadline)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.horizontal, 16)
                        .padding(.bottom, 64)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .task(id: noticeID) {
                guard noticeID != nil else { return }
                do {
                    try await Task.sleep(for: .seconds(2.5))
                    downloadNotice = nil
                } catch {}
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
        let sources = deck.localPages.map { [$0[page].absoluteString] } ?? deck.slides[page]
        return ([api.service.rawValue, api.userID] + sources).joined(separator: "\n")
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
                guard let data = try? await deck.pageData(next, api: api), !Task.isCancelled,
                      appearance.cachePPT, let bitmap = UIImage(data: data) else { continue }
                preloadStore.store(data, key: key)
                appearance.cachePPTImage(bitmap, key: key)
            }
        }
    }

    private var readerMenu: some View {
        Menu("操作", systemImage: "ellipsis.circle") {
            if classroomModel != nil, danmuEnabled {
                Toggle("显示弹幕", isOn: $showsScrollingDanmu)
            }
            if classroomModel != nil {
                Button("课堂弹幕", systemImage: "text.bubble") { showsDanmu = true }
            }
            Button("保存当前图片", systemImage: "photo") { save() }.disabled(image == nil || exports.running)
            Button("导出 PPTX", systemImage: "document") { preparePPTX() }.disabled(exports.running)
            Button("导出 ZIP", systemImage: "archivebox") { exports.start(deck, api: api, pptx: false, name: nil) }.disabled(exports.running)
            Button("导出 PDF", systemImage: "doc.richtext") {
                exports.start(deck, api: api, pptx: false, name: nil, pdf: true)
            }
            .disabled(exports.running)
            if deck.localPages == nil, !api.userID.isEmpty {
                Button("保存至离线课件库", systemImage: "arrow.down.circle") {
                    let message = offlineDownloads.enqueue(deck: deck, api: api)
                    downloadNotice = message
                    noticeID = UUID()
                    AccessibilityNotification.Announcement(message).post()
                }
            }
            Button("重新载入当前页", systemImage: "arrow.clockwise") {
                if let key = slideCacheKey {
                    appearance.removeCachedPPTImage(key)
                    preloadStore.remove(key)
                }
                retry += 1
            }
        }
    }

    @ViewBuilder private var readerStatus: some View {
        if followTeacher != nil, let followError {
            Text(followError).font(.footnote).appTextStyle(.detail, fallback: .secondary)
            Button("重试同步") { retryFollow?() }
        }
        if exports.running {
            ExportProgressView(export: exports).padding(.horizontal)
        }
        if let file = exports.file {
            ShareLink(item: file) { Label("分享导出文件", systemImage: "square.and.arrow.up") }
        }
        if let exportError = exports.error {
            Text(exportError).font(.footnote).appTextStyle(.detail, fallback: .secondary)
        }
    }

    private func resetZoom() {
        zoom = 1
        pan = .zero
    }

    private func clampedPan(_ offset: CGSize, scale: CGFloat, image: UIImage, in size: CGSize) -> CGSize {
        let fit = min(size.width / max(1, image.size.width), size.height / max(1, image.size.height))
        let x = max(0, (image.size.width * fit * scale - size.width) / 2)
        let y = max(0, (image.size.height * fit * scale - size.height) / 2)
        return CGSize(width: min(x, max(-x, offset.width)), height: min(y, max(-y, offset.height)))
    }

    private func slideViewport(toggleControls: (() -> Void)? = nil) -> some View {
        GeometryReader { geometry in
            let size = geometry.size
            let scale = min(5, max(0.5, zoom * pinchScale))
            ZStack {
                Color.clear
                if let image {
                    let offset = clampedPan(
                        CGSize(width: pan.width + dragOffset.width, height: pan.height + dragOffset.height),
                        scale: scale, image: image, in: size
                    )
                    slideImage(image)
                        .frame(width: size.width, height: size.height)
                        .scaleEffect(scale)
                        .offset(offset)
                        .accessibilityActions {
                            if let toggleControls {
                                Button("显示或隐藏播放器控件", action: toggleControls)
                            }
                        }
                } else {
                    ProgressView()
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
            .overlay {
                if danmuEnabled, showsScrollingDanmu, let classroomModel {
                    ScrollingDanmuView(danmu: classroomModel.danmu, topInset: toggleControls == nil ? 8 : 56)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
            .gesture(TapGesture(count: 2).onEnded {
                guard image != nil else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    if zoom == 1 { zoom = 2 } else { resetZoom() }
                }
            }.exclusively(before: TapGesture().onEnded { toggleControls?() }))
            .simultaneousGesture(MagnifyGesture()
                .updating($pinchScale) { value, state, _ in state = value.magnification }
                .onEnded { value in
                    guard let image else { return }
                    zoom = min(5, max(0.5, zoom * value.magnification))
                    if abs(zoom - 1) < 0.02 { resetZoom() }
                    pan = clampedPan(pan, scale: zoom, image: image, in: size)
                })
            .simultaneousGesture(DragGesture(minimumDistance: 20)
                .updating($dragOffset) { value, state, _ in
                    if zoom > 1 && pinchScale == 1 { state = value.translation }
                }
                .onEnded { value in
                    guard let image, pinchScale == 1 else { return }
                    let movement = value.translation
                    if zoom > 1 {
                        pan = clampedPan(
                            CGSize(width: pan.width + movement.width, height: pan.height + movement.height),
                            scale: zoom, image: image, in: size
                        )
                    } else if abs(movement.width) >= 44, abs(movement.width) > abs(movement.height) {
                        movePage(by: movement.width < 0 ? 1 : -1)
                    }
                })
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
        ZStack {
            slideViewport {
                withAnimation(.easeInOut(duration: 0.2)) { showsLandscapeControls.toggle() }
            }
            .ignoresSafeArea()

            if showsLandscapeControls {
                VStack {
                    HStack(spacing: 12) {
                        Button("关闭") { dismiss() }
                            .modifier(ReaderControlButton())
                        Text(deck.title)
                            .font(.headline)
                            .appTextStyle(.smallTitle, fallback: .primary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityAction(named: Text("隐藏播放器控件")) {
                                showsLandscapeControls = false
                            }
                        readerMenu.modifier(ReaderControlButton())
                    }
                    .padding(.horizontal, 8)
                    Spacer(minLength: 0)
                    readerStatus
                    cornerControls
                }
                .padding(.top, 4)
                .transition(.opacity)

                HStack {
                    landscapePageButton("上一页", icon: "chevron.left", offset: -1)
                    Spacer(minLength: 0)
                    landscapePageButton("下一页", icon: "chevron.right", offset: 1)
                }
                .padding(.horizontal, 8)
                .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            if zoom != 1 { resetZoomButton.padding(.bottom, 8) }
        }
    }

    private var resetZoomButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { resetZoom() }
        } label: {
            Label("还原", systemImage: "arrow.counterclockwise")
                .frame(minHeight: 44)
        }
        .modifier(ReaderControlButton())
        .accessibilityLabel("还原课件缩放")
    }

    @ViewBuilder private var cornerControls: some View {
        if let followTeacher {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    pageBadge
                    Spacer(minLength: 0)
                    FollowTeacherButton(isFollowing: followTeacher)
                }
                VStack(spacing: 4) {
                    pageBadge.frame(maxWidth: .infinity, alignment: .leading)
                    FollowTeacherButton(isFollowing: followTeacher)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        } else {
            pageBadge
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
    }

    @ViewBuilder private var pageBadge: some View {
        let badge = pageCount
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
            .fixedSize(horizontal: true, vertical: false)
        if #available(iOS 26.0, *) {
            badge.glassEffect(.regular, in: .capsule)
        } else {
            badge.background(.regularMaterial, in: Capsule())
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

    private var portraitControls: some View {
        VStack(spacing: 6) {
            if zoom != 1 { resetZoomButton }
            if let followTeacher {
                FollowTeacherButton(isFollowing: followTeacher)
            }
            HStack(spacing: 12) {
                landscapePageButton("上一页", icon: "chevron.left", offset: -1)
                pageCount
                landscapePageButton("下一页", icon: "chevron.right", offset: 1)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private var pageCount: some View {
        Text("\(index + 1) / \(deck.slides.count)")
            .font(.footnote.monospacedDigit())
            .appTextStyle(.detail, fallback: .secondary)
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


private struct FollowTeacherButton: View {
    @Binding var isFollowing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let button = Button {
            isFollowing.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isFollowing ? "checkmark.circle.fill" : "hand.draw")
                    .frame(width: 20)
                    .accessibilityHidden(true)
                ZStack(alignment: .leading) {
                    Text("跟随老师").hidden().accessibilityHidden(true)
                    Text("自由浏览").hidden().accessibilityHidden(true)
                    Text(isFollowing ? "跟随老师" : "自由浏览")
                        .contentTransition(.opacity)
                }
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Capsule())
        }
        .buttonBorderShape(.capsule)
        .fixedSize()
        .accessibilityLabel("跟随老师")
        .accessibilityValue(isFollowing ? "已开启" : "自由浏览")
        .accessibilityAddTraits(isFollowing ? .isSelected : [])
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isFollowing)

        let tint: Color? = isFollowing ? .blue.opacity(0.28) : nil
        if #available(iOS 26.1, *) {
            button.buttonStyle(GlassButtonStyle(.regular.tint(tint)))
        } else if #available(iOS 26.0, *) {
            button
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(tint).interactive(), in: .capsule)
        } else {
            button.buttonStyle(.bordered).tint(isFollowing ? .blue : nil)
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
                 followError: followTeacher ? error : nil, retryFollow: { retry += 1 }, classroomModel: model)
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


private struct ReaderControlButton: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.large)
        } else {
            content.buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large)
        }
    }
}
