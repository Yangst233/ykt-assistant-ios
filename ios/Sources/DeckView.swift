import SwiftUI
import Photos

@MainActor
struct DeckView: View {
    let deck: Deck
    let api: RainAPI
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var image: UIImage?
    @State private var error: String?
    @State private var share: URL?
    @State private var operation: Task<Void, Never>?
    @State private var exporting = false
    @State private var progress = 0
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
                HStack {
                    Button("上一页", systemImage: "chevron.left") { index -= 1 }.disabled(index == 0)
                    Spacer()
                    Text("\(index + 1) / \(deck.slides.count)")
                    Spacer()
                    Button("下一页", systemImage: "chevron.right") { index += 1 }.disabled(index + 1 == deck.slides.count)
                }
                .padding()
                if exporting {
                    ProgressView(value: Double(progress), total: Double(deck.slides.count))
                    Button("取消导出") { operation?.cancel() }
                }
                if let share { ShareLink(item: share) { Label("分享导出文件", systemImage: "square.and.arrow.up") } }
            }
            .navigationTitle(deck.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu("操作", systemImage: "ellipsis.circle") {
                        Button("保存当前图片") { save() }.disabled(image == nil || exporting)
                        Button("导出 PPTX") { export(pptx: true) }.disabled(exporting)
                        Button("导出 ZIP") { export(pptx: false) }.disabled(exporting)
                        Button("重新载入当前页") { retry += 1 }
                    }
                }
            }
            .task(id: "\(index):\(retry)") {
                image = nil
                zoom = 1
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
            .alert("图片已保存", isPresented: $saved) { Button("好") {} }
            .alert("课件", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好") { error = nil }
            } message: { Text(error ?? "") }
        }
    }

    private func clearShare() {
        if let share { try? FileManager.default.removeItem(at: share.deletingLastPathComponent()) }
        share = nil
    }

    private func export(pptx: Bool) {
        clearShare()
        progress = 0
        exporting = true
        operation = Task {
            defer { exporting = false }
            do {
                let file = try await DeckExport.create(deck, api: api, pptx: pptx) { progress = $0 }
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
