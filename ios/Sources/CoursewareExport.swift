import SwiftUI

@MainActor
final class CoursewareExport: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var page: Int? = 1
    @Published private(set) var total = 0
    @Published private(set) var pptx = false
    @Published private(set) var file: URL?
    @Published private(set) var error: String?
    private var task: Task<Void, Never>?

    func start(_ deck: Deck, api: RainAPI, pptx: Bool, name: String?) {
        guard !running else { return }
        clear()
        page = 1
        total = deck.slides.count
        self.pptx = pptx
        running = true
        task = Task {
            defer { running = false; task = nil }
            do {
                let result = try await DeckExport.create(deck, api: api, pptx: pptx, filename: name) { self.page = $0 }
                if Task.isCancelled { try? FileManager.default.removeItem(at: result.deletingLastPathComponent()) }
                else { file = result }
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    func cancel() { task?.cancel() }

    func clear() {
        guard !running else { return }
        if let file { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        file = nil
        error = nil
    }
}

struct ExportProgressView: View {
    @ObservedObject var export: CoursewareExport

    var body: some View {
        ProgressView(value: Double(export.page.map { $0 - 1 } ?? export.total), total: Double(max(1, export.total))) {
            if let page = export.page {
                Text("正在下载第 \(page) 页，共 \(export.total) 页")
            } else {
                Text(export.pptx ? "正在生成 PPTX…" : "正在整理 ZIP…")
            }
        }
        Button("取消导出") { export.cancel() }
    }
}

struct FloatingExportView: View {
    @ObservedObject var export: CoursewareExport

    var body: some View {
        if export.running || export.file != nil || export.error != nil {
            VStack(alignment: .leading, spacing: 8) {
                if export.running {
                    ExportProgressView(export: export)
                } else {
                    if let file = export.file {
                        ShareLink(item: file) { Label("分享导出文件", systemImage: "square.and.arrow.up") }
                    }
                    if let error = export.error { Text(error).font(.footnote) }
                    Button("关闭") { export.clear() }
                }
            }
            .padding(14)
            .frame(maxWidth: 300, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
    }
}
