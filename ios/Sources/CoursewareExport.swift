import SwiftUI

@MainActor
final class CoursewareExport: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var page: Int? = 1
    @Published private(set) var total = 0
    @Published private(set) var pptx = false
    @Published private(set) var filename = ""
    @Published private(set) var file: URL?
    @Published private(set) var error: String?
    private var task: Task<Void, Never>?

    func start(_ deck: Deck, api: RainAPI, pptx: Bool, name: String?) {
        guard !running else { return }
        clear()
        page = 1
        total = deck.slides.count
        self.pptx = pptx
        let stem = DeckExport.exportStem(title: deck.title, pptx: pptx, filename: name)
        filename = stem + (pptx ? ".pptx" : ".zip")
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
                VStack(alignment: .leading, spacing: 4) {
                    Text("正在下载 \(export.filename)").lineLimit(2)
                    Text("第 \(page) 页，共 \(export.total) 页").font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Text(export.pptx ? "正在生成 PPTX…" : "正在整理 ZIP…")
            }
        }
        Button("取消导出") { export.cancel() }
    }
}

struct FloatingExportView: View {
    @ObservedObject var export: CoursewareExport
    @State private var location: CGPoint?
    @State private var cardHeight: CGFloat = 0
    @GestureState private var translation: CGSize = .zero

    var body: some View {
        if export.running || export.file != nil || export.error != nil {
            GeometryReader { bounds in
                let width = min(300, max(0, bounds.size.width - 24))
                let center = clamped(location ?? CGPoint(x: bounds.size.width, y: bounds.size.height - 56),
                                     in: bounds.size, width: width)
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .contentShape(Rectangle())
                        .accessibilityHidden(true)
                        .gesture(DragGesture(coordinateSpace: .named("exportFloat"))
                            .updating($translation) { value, state, _ in state = value.translation }
                            .onEnded { value in
                                location = clamped(offset(center, by: value.translation), in: bounds.size, width: width)
                            })
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
                .frame(width: width, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardHeight = $0 }
                .position(clamped(offset(center, by: translation), in: bounds.size, width: width))
            }
            .coordinateSpace(name: "exportFloat")
        }
    }

    private func clamped(_ point: CGPoint, in bounds: CGSize, width: CGFloat) -> CGPoint {
        let horizontal = min(bounds.width / 2, width / 2 + 12)
        let vertical = min(bounds.height / 2, cardHeight / 2 + 8)
        return CGPoint(x: min(max(point.x, horizontal), bounds.width - horizontal),
                       y: min(max(point.y, vertical), bounds.height - vertical))
    }
}

private func offset(_ point: CGPoint, by translation: CGSize) -> CGPoint {
    CGPoint(x: point.x + translation.width, y: point.y + translation.height)
}
