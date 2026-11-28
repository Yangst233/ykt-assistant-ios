import SwiftUI

@MainActor
struct OfflineDeckLibrary: View {
    @ObservedObject var model: AppModel
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
struct OfflineDownloadView: View {
    let deck: Deck
    let api: RainAPI
    @Environment(\.dismiss) private var dismiss
    @State private var attempt = 0
    @State private var page = 0
    @State private var complete = false
    @State private var error: String?

    var body: some View {
        MaterialForm {
            AppSection(deck.title) {
                if complete {
                    Label("已保存到离线课件库", systemImage: "checkmark.circle")
                } else if let error {
                    Text(error)
                    Button("重试") { attempt += 1 }
                } else {
                    ProgressView("正在下载第 \(page) 页，共 \(deck.slides.count) 页",
                                 value: Double(page), total: Double(max(1, deck.slides.count)))
                }
            }
        }
        .wallpaperSurface()
        .appNavigationTitle("下载课件")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(complete || error != nil ? "关闭" : "取消") { dismiss() }
            }
        }
        .task(id: attempt) {
            error = nil
            page = 0
            do {
                let directory = try OfflineStorage.directory(api.service.rawValue + ":" + api.userID)
                try await OfflineStorage.download(deck, api: api, into: directory) { page = $0 }
                complete = true
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}
