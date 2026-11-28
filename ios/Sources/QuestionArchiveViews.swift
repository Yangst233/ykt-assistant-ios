import SwiftUI

struct ArchivedQuestion: Identifiable {
    let id: String
    let title: String
    let question: ClassroomQuestion
}

@MainActor
struct LiveBatchAnalysisView: View {
    @ObservedObject var model: QuizModel
    @State private var source: (RainAPI, String, [ArchivedQuestion])?
    @State private var error: String?
    @State private var attempt = 0

    var body: some View {
        Group {
            if let (api, account, questions) = source, !questions.isEmpty {
                BatchAnalysisView(api: api, account: account, questions: questions)
            } else {
                MaterialList {
                    if let error { Text(error); Button("重试") { attempt += 1 } }
                    else if source != nil { Text("雨课堂尚未返回可供分析的题目。") }
                    else { ProgressView("正在加载课堂题目") }
                }
                .wallpaperSurface()
                .appNavigationTitle("批量 AI 分析")
            }
        }
        .task(id: attempt) {
            error = nil
            do { source = try await model.batchSource() }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}

@MainActor
struct HistoricalQuestionsView: View {
    let api: RainAPI
    let account: String
    let lessonID: String
    let presentations: [JSON]
    @State private var batch: [ArchivedQuestion] = []
    @State private var problems: [String] = []
    @State private var loading = true
    @State private var attempt = 0

    var body: some View {
        MaterialList {
            if loading { ProgressView("正在加载历史习题") }
            if !loading, batch.isEmpty, problems.isEmpty {
                ContentUnavailableView("暂无可查看的历史习题", systemImage: "questionmark.bubble",
                    description: Text("仅显示雨课堂对当前账号开放的题目。"))
            }
            if !problems.isEmpty {
                AppSection("部分课件加载失败") {
                    ForEach(problems.indices, id: \.self) { index in Text(problems[index]) }
                    Button("重试") { attempt += 1 }
                }
            }
            if batch.contains(where: { (1...6).contains($0.question.type) }) {
                NavigationLink {
                    BatchAnalysisView(api: api, account: account, questions: batch)
                } label: { NavigationRowLabel { Label("批量 AI 分析", systemImage: "sparkles") } }
                .glassNavigationInteraction()
            }
            ForEach(batch) { item in
                NavigationLink {
                    HistoricalQuestionDetail(api: api, item: item)
                } label: {
                    NavigationRowLabel {
                        VStack(alignment: .leading) {
                            Text(item.title)
                            let text = QuizAI.plain(item.question.specification?.field("body") ?? "")
                            if !text.isEmpty { Text(text).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
                        }
                    }
                }
                .glassNavigationInteraction()
            }
        }
        .wallpaperSurface()
        .appNavigationTitle("历史习题")
        .task(id: attempt) { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        var results: [ArchivedQuestion] = []
        var failures: [String] = []
        var seen: Set<String> = []
        for presentation in presentations {
            let id = presentation.field("presentationId")
            guard !id.isEmpty, seen.insert(id).inserted else { continue }
            let title = presentation.field("title").nonempty ?? "课件"
            do {
                let cache = "questions-" + OfflineStorage.key(lessonID + ":" + id) + ".json"
                let slides: [JSON]
                do {
                    let (_, rows) = try await api.historicalSlides(lessonID: lessonID, presentationID: id)
                    try Task.checkCancellation()
                    slides = rows
                    try? OfflineStorage.write(["slides": rows], name: cache, account: account)
                } catch {
                    try Task.checkCancellation()
                    guard let rows = OfflineStorage.read(cache, account: account)?["slides"] as? [JSON] else { throw error }
                    slides = rows
                    failures.append(title + "（显示缓存）：" + error.localizedDescription)
                }
                for (offset, slide) in slides.enumerated() {
                    let spec = slide["problem"] as? JSON
                    guard spec != nil || ["1", "true"].contains(slide.field("hasProblem").lowercased()) else { continue }
                    let problemID = spec?.field("problemId").nonempty ?? slide.field("id").nonempty ?? String(offset)
                    let key = "history:\(lessonID):\(id):\(problemID)"
                    let page = slide.field("index").nonempty ?? String(offset + 1)
                    let question = ClassroomQuestion(id: problemID, presentation: id, eventTime: 0,
                                                     specification: spec, slide: slide)
                    results.append(.init(id: key, title: "\(title) · 第 \(page) 页", question: question))
                }
            } catch {
                guard !Task.isCancelled else { return }
                failures.append(title + "：" + error.localizedDescription)
            }
        }
        guard !Task.isCancelled else { return }
        batch = results
        problems = failures
    }
}

private struct HistoricalQuestionDetail: View {
    let api: RainAPI
    let item: ArchivedQuestion
    @State private var image: UIImage?
    @State private var imageError: String?

    var body: some View {
        MaterialList {
            AppSection("题目") {
                if let spec = item.question.specification {
                    let body = QuizAI.plain(spec.field("body"))
                    if !body.isEmpty { Text(body).textSelection(.enabled) }
                    ForEach(Array(item.question.choices.enumerated()), id: \.offset) { _, option in
                        Text(option.field("key") + "  " + QuizAI.plain(option.field("value")))
                    }
                    if let answers = spec["answers"] as? [String], !answers.isEmpty {
                        LabeledContent("雨课堂公布答案", value: answers.map(QuizAI.plain).joined(separator: "、"))
                    }
                } else { Text("雨课堂仅提供该题的课件页。").foregroundStyle(.secondary) }
                if let image { Image(uiImage: image).resizable().scaledToFit().accessibilityLabel("题目课件页") }
                else if let imageError { Text(imageError).foregroundStyle(.secondary) }
                else if !item.question.imageURLs.isEmpty { ProgressView("正在载入题图") }
            }
        }
        .wallpaperSurface()
        .appNavigationTitle(item.title)
        .task {
            guard !item.question.imageURLs.isEmpty else { return }
            do {
                let data = try await api.slideImage(item.question.imageURLs)
                guard let bitmap = UIImage(data: data) else { throw RainError.invalid("题图") }
                image = bitmap
            } catch { if !Task.isCancelled { imageError = error.localizedDescription } }
        }
    }
}

struct StoredAIAnswer: Codable, Identifiable {
    let id: String
    let title: String
    let question: String
    let answer: String
    let reason: String
    let answered: Bool
    let date: Date

    static func read(account: String) -> [Self] {
        guard let data = OfflineStorage.read("answers.json", account: account)?["records"] as? String,
              let bytes = Data(base64Encoded: data) else { return [] }
        return (try? JSONDecoder().decode([Self].self, from: bytes)) ?? []
    }

    @MainActor func save(account: String) throws {
        var records = Self.read(account: account)
        records.removeAll { $0.id == id }
        records.insert(self, at: 0)
        let bytes = try JSONEncoder().encode(records)
        try OfflineStorage.write(["records": bytes.base64EncodedString()], name: "answers.json", account: account)
    }
}

@MainActor
struct BatchAnalysisView: View {
    let api: RainAPI
    let account: String
    let questions: [ArchivedQuestion]
    @State private var selection: Set<String> = []
    @State private var failures: [String: String] = [:]
    @State private var completed = 0
    @State private var total = 0
    @State private var work: [ArchivedQuestion] = []
    @State private var runID: UUID?
    @State private var confirm = false
    @State private var includeImages = false
    @State private var configuration: AIConfiguration?
    @State private var error: String?
    @Environment(\.scenePhase) private var scenePhase

    private var eligible: [ArchivedQuestion] { questions.filter { (1...6).contains($0.question.type) } }

    var body: some View {
        MaterialList {
            AppSection("批量分析") {
                Toggle("附带题目的课件截图", isOn: $includeImages).disabled(runID != nil)
                if let error { Text(error).foregroundStyle(.secondary) }
                if total > 0 { ProgressView("已处理 \(completed) / \(total) 题", value: Double(completed), total: Double(total)) }
                if runID != nil {
                    Button("取消分析") { runID = nil }
                } else {
                    Button("开始分析（\(selection.count) 题）") {
                        prepare(eligible.filter { selection.contains($0.id) })
                    }
                    .disabled(selection.isEmpty)
                    if !failures.isEmpty {
                        Button("重试失败项") { prepare(eligible.filter { failures[$0.id] != nil }) }
                    }
                }
                NavigationLink {
                    AIAnswerLibrary(account: account)
                } label: { NavigationRowLabel { Text("查看 AI 答案库") } }
                .glassNavigationInteraction()
            }
            AppSection("选择题目") {
                Button("全选") { selection = Set(eligible.map(\.id)) }
                Button("取消全选") { selection.removeAll() }
                ForEach(eligible) { item in
                    Toggle(isOn: Binding(get: { selection.contains(item.id) }, set: {
                        if $0 { selection.insert(item.id) } else { selection.remove(item.id) }
                    })) {
                        VStack(alignment: .leading) {
                            Text(item.title)
                            Text(QuizAI.plain(item.question.specification?.field("body") ?? "")).lineLimit(2)
                            if let failure = failures[item.id] { Text(failure).font(.footnote).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            .disabled(runID != nil)
        }
        .wallpaperSurface()
        .appNavigationTitle("批量 AI 分析")
        .alert("发送选中的题目？", isPresented: $confirm) {
            Button("取消", role: .cancel) {}
            Button("发送并分析") { runID = UUID() }
        } message: {
            Text("将向 \((try? configuration?.endpoint())?.host ?? "所配置的服务") 发送 \(work.count) 道题的题干和选项。\(includeImages ? "有题图的题目会附带课件截图。" : "")")
        }
        .task(id: runID) {
            guard let id = runID, let configuration else { return }
            await analyze(id, configuration: configuration)
        }
        .onChange(of: scenePhase) { _, phase in if phase == .background { runID = nil } }
    }

    private func prepare(_ items: [ArchivedQuestion]) {
        do {
            let config = try AIConfiguration.load()
            _ = try config.endpoint()
            configuration = config
            work = items
            error = nil
            confirm = true
        } catch { self.error = error.localizedDescription }
    }

    private func analyze(_ id: UUID, configuration: AIConfiguration) async {
        total = work.count
        completed = 0
        let images = includeImages
        for item in work {
            guard runID == id, !Task.isCancelled else { return }
            let q = item.question
            do {
                let image = images && !q.imageURLs.isEmpty ? try await api.slideImage(q.imageURLs) : nil
                let result = try await QuizAI.analyze(q, configuration: configuration, image: image)
                try Task.checkCancellation()
                guard runID == id else { return }
                let draft = result.draft
                let answer = [q.keys.filter(draft.options.contains).joined(separator: "、"),
                              draft.blanks.joined(separator: " / "), draft.text]
                    .filter { !$0.isEmpty }.joined(separator: "\n")
                try StoredAIAnswer(id: item.id, title: item.title, question: QuizAI.plain(q.specification?.field("body") ?? ""),
                                   answer: answer, reason: result.reason, answered: result.status == "answered",
                                   date: Date()).save(account: account)
                failures[item.id] = nil
            } catch {
                guard runID == id, !Task.isCancelled else { return }
                failures[item.id] = error.localizedDescription
            }
            completed += 1
        }
        if runID == id { runID = nil }
    }
}

struct AIAnswerLibrary: View {
    let account: String?
    @State private var search = ""
    @State private var onlyMissing = false
    @State private var answers: [StoredAIAnswer] = []

    var body: some View {
        MaterialList {
            Toggle("仅显示无答案", isOn: $onlyMissing)
            if answers.isEmpty { ContentUnavailableView("暂无分析记录", systemImage: "tray") }
            ForEach(answers.filter {
                (!onlyMissing || !$0.answered) &&
                (search.isEmpty || [$0.title, $0.question, $0.answer].contains { $0.localizedCaseInsensitiveContains(search) })
            }) { entry in
                AppSection(entry.title) {
                    if !entry.question.isEmpty { Text(entry.question).textSelection(.enabled) }
                    Text(entry.answered ? entry.answer : "模型未给出答案").textSelection(.enabled)
                    if !entry.reason.isEmpty { Text(entry.reason).foregroundStyle(.secondary).textSelection(.enabled) }
                    Text(entry.date.formatted()).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .wallpaperSurface()
        .appNavigationTitle("AI 答案库")
        .searchable(text: $search, prompt: "搜索题目或答案")
        .onAppear { answers = account.map(StoredAIAnswer.read(account:)) ?? [] }
        .onChange(of: account) { _, value in answers = value.map(StoredAIAnswer.read(account:)) ?? [] }
    }
}
