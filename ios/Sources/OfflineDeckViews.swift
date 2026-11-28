import SwiftUI

@MainActor
struct OfflineDeckLibrary: View {
    @ObservedObject var model: AppModel
    @EnvironmentObject private var queue: OfflineDownloadQueue
    @State private var records: [OfflineStorage.SavedDeck] = []
    @State private var search = ""
    @State private var error: String?
    @State private var pendingDelete: OfflineStorage.SavedDeck?

    var body: some View {
        MaterialList {
            if model.selected == nil {
                ContentUnavailableView("请登录账号", systemImage: "person.crop.circle")
            } else if records.isEmpty {
                ContentUnavailableView("暂无离线课件", systemImage: "arrow.down.circle",
                    description: Text("在 PPT 播放器的操作菜单中下载课件。"))
            }
            if let error { Text(error).foregroundStyle(.secondary) }
            ForEach(records.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }) { record in
                AppSection(record.title) {
                    Button {
                        do {
                            guard let account = model.selected else { return }
                            model.deck = record.deck(in: try OfflineStorage.directory(account))
                        } catch { self.error = error.localizedDescription }
                    } label: {
                        NavigationRowLabel {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("查看课件")
                                Text("\(record.count) 页 · \(ByteCountFormatter.string(fromByteCount: Int64(record.bytes), countStyle: .file))")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .glassNavigationInteraction()
                    Button("删除下载", role: .destructive) { pendingDelete = record }
                }
            }
        }
        .wallpaperSurface()
        .appNavigationTitle("离线课件库")
        .searchable(text: $search, prompt: "搜索课件")
        .onAppear(perform: reload)
        .onChange(of: queue.libraryRevision) { _, _ in reload() }
        .onChange(of: model.selected) { _, _ in pendingDelete = nil; reload() }
        .confirmationDialog("删除离线课件？", isPresented: Binding(get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }), presenting: pendingDelete) { record in
            Button("删除", role: .destructive) {
                guard let account = model.selected else { return }
                do {
                    let directory = try OfflineStorage.directory(account)
                    try FileManager.default.removeItem(at: directory.appendingPathComponent(record.id.uuidString))
                    reload()
                } catch { self.error = error.localizedDescription }
            }
        }
    }

    private func reload() {
        records = []
        error = nil
        guard let account = model.selected else { return }
        do { records = OfflineStorage.decks(try OfflineStorage.directory(account)) }
        catch { self.error = error.localizedDescription }
    }
}

@MainActor
struct OfflineDownloadList: View {
    let account: String?
    @EnvironmentObject private var queue: OfflineDownloadQueue

    var body: some View {
        MaterialList {
            let entries = queue.entries.filter { $0.account == account }
            if entries.isEmpty {
                ContentUnavailableView("暂无下载任务", systemImage: "arrow.down.circle",
                    description: Text("在课件播放器中选择「保存至离线课件库」即可添加任务。"))
            }
            ForEach(entries.reversed()) { entry in
                AppSection(entry.title) {
                    switch entry.status {
                    case .queued:
                        Label("等待下载", systemImage: "clock")
                        Button("取消下载", role: .destructive) { queue.cancel(entry.id) }
                    case .downloading, .cancelling:
                        let cancelling = entry.status == .cancelling
                        ProgressView(cancelling ? "正在取消…" : "正在下载第 \(entry.page) 页，共 \(entry.total) 页",
                                     value: Double(max(0, entry.page - 1)), total: Double(entry.total))
                        if !cancelling {
                            Button("取消下载", role: .destructive) { queue.cancel(entry.id) }
                        }
                    case .saved:
                        Label("已保存至离线课件库", systemImage: "checkmark.circle")
                        removeRecord(entry)
                    case .cancelled:
                        Label("已取消", systemImage: "xmark.circle")
                        Button("重新下载") { queue.retry(entry.id) }
                        removeRecord(entry)
                    case .failed(let error):
                        Label("下载失败", systemImage: "exclamationmark.circle")
                        Text(error).font(.footnote).foregroundStyle(.secondary)
                        Button("重试") { queue.retry(entry.id) }
                        removeRecord(entry)
                    }
                }
            }
        }
        .wallpaperSurface()
        .appNavigationTitle("下载列表")
    }

    private func removeRecord(_ entry: OfflineDownloadQueue.Entry) -> some View {
        Button("移除任务记录", role: .destructive) { queue.remove(entry.id) }
    }
}
