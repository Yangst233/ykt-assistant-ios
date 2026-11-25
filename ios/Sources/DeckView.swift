import SwiftUI
import Photos

@MainActor
struct DeckView: View {
    let deck: Deck
    let api: RainAPI
    var followTeacher: Binding<Bool>? = nil
    var teacherPage: Int? = nil
    var followError: String? = nil
    var retryFollow: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var image: UIImage?
    @State private var error: String?
    @State private var share: URL?
    @State private var operation: Task<Void, Never>?
    @State private var exporting = false
    @State private var downloadPage: Int? = 1
    @State private var exportTotal = 0
    @State private var exportPPTX = false
    @State private var exportName = ""
    @State private var namingDeck: Deck?
    @State private var retry = 0
    @State private var saved = false
    @State private var zoom = 1.0

    var body: some View {
        NavigationStack {
            VStack {
                if let image {
                    ScrollView([.horizontal, .vertical]) {
                        Image(uiImage: image).resizable().scaledToFit()
                            .containerRelativeFrame(.horizontal) { size, _ in size * zoom }
                            .accessibilityLabel("课件第 \(index + 1) 页")
                    }
                    .onTapGesture(count: 2) { zoom = zoom == 1 ? 2 : 1 }
                } else {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                if let followTeacher {
                    Toggle("跟随老师", isOn: followTeacher)
                        .padding(.horizontal)
                    if let followError {
                        Text(followError).font(.footnote).foregroundStyle(.secondary)
                        Button("重试同步") { retryFollow?() }
                    }
                }
                pageControls
                if exporting {
                    ProgressView(value: Double(downloadPage.map { $0 - 1 } ?? exportTotal),
                                 total: Double(exportTotal)) {
                        if let page = downloadPage {
                            Text("正在下载第 \(page) 页，共 \(exportTotal) 页")
                        } else {
                            Text(exportPPTX ? "正在生成 PPTX…" : "正在整理 ZIP…")
                        }
                    }
                    .padding(.horizontal)
                    Button("取消导出") { operation?.cancel() }
                }
                if let share { ShareLink(item: share) { Label("分享导出文件", systemImage: "square.and.arrow.up") } }
            }
            .wallpaperSurface()
            .navigationTitle(deck.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu("操作", systemImage: "ellipsis.circle") {
                        Button("保存当前图片", systemImage: "photo") { save() }.disabled(image == nil || exporting)
                        Button("导出 PPTX", systemImage: "document") { preparePPTX() }.disabled(exporting)
                        Button("导出 ZIP", systemImage: "archivebox") { export(deck, pptx: false, name: nil) }.disabled(exporting)
                        Button("重新载入当前页", systemImage: "arrow.clockwise") { retry += 1 }
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
                image = nil
                zoom = 1
                guard deck.slides.indices.contains(index) else { return }
                do {
                    let data = try await api.slideImage(deck.slides[index])
                    try Task.checkCancellation()
                    guard let bitmap = UIImage(data: data) else { throw RainError.invalid("课件图片") }
                    image = bitmap
                } catch {
                    if !Task.isCancelled { self.error = error.localizedDescription }
                }
            }
            .onDisappear {
                operation?.cancel()
                clearShare()
            }
            .sheet(isPresented: Binding(get: { namingDeck != nil }, set: { if !$0 { namingDeck = nil } })) {
                NavigationStack {
                    MaterialForm {
                        TextField("PPTX 文件名", text: $exportName)
                    }
                    .wallpaperSurface()
                    .navigationTitle("导出 PPTX")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("取消") { namingDeck = nil } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("导出") {
                                guard let source = namingDeck else { return }
                                namingDeck = nil
                                export(source, pptx: true, name: exportName)
                            }
                        }
                    }
                }
                .presentationDetents([.medium])
            }
            .alert("图片已保存", isPresented: $saved) { Button("好") {} }
            .alert("课件", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好") { error = nil }
            } message: { Text(error ?? "") }
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
            index += offset
        } label: {
            Label(title, systemImage: icon)
                .labelStyle(.iconOnly)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .disabled(followTeacher?.wrappedValue == true || !deck.slides.indices.contains(index + offset))
    }

    private func clearShare() {
        if let share { try? FileManager.default.removeItem(at: share.deletingLastPathComponent()) }
        share = nil
    }

    private func preparePPTX() {
        exportName = DeckExport.fileStem(deck.title, fallback: "Slides")
        namingDeck = deck
    }

    private func export(_ source: Deck, pptx: Bool, name: String?) {
        clearShare()
        downloadPage = 1
        exportTotal = source.slides.count
        exportPPTX = pptx
        exporting = true
        operation = Task {
            defer { exporting = false }
            do {
                let file = try await DeckExport.create(source, api: api, pptx: pptx, filename: name) { downloadPage = $0 }
                if Task.isCancelled { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
                else { share = file }
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
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
