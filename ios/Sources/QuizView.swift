import SwiftUI

struct ClassroomQuestionsView: View {
    @ObservedObject var model: QuizModel
    var body: some View {
        List {
            if model.questions.isEmpty {
                ContentUnavailableView("尚未收到课堂题目", systemImage: "questionmark.bubble")
            }
            ForEach(Array(model.questions.enumerated().reversed()), id: \.element.id) { index, q in
                NavigationLink {
                    QuestionView(model: model, id: q.id)
                } label: {
                    Label("题目 \(index + 1)", systemImage: q.submitted ? "checkmark.circle" : "questionmark.circle")
                }
            }
        }
        .wallpaperSurface()
        .navigationTitle("课堂题目")
    }
}

struct QuestionView: View {
    @ObservedObject var model: QuizModel
    let id: String
    @State private var confirmSubmit = false
    @State private var confirmAI = false
    @State private var confirmApply = false
    @State private var useImage = false
    @State private var settings = false
    @State private var localError: String?
    @State private var configuration: AIConfiguration?
    @State private var confirmRound: UUID?

    var body: some View {
        List {
            if let q = model.question(id) {
                if let spec = q.specification {
                    Section {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in Text(status(q)) }
                        let text = QuizAI.plain(spec.field("body"))
                        if !text.isEmpty { Text(text).textSelection(.enabled) }
                        if !q.imageURLs.isEmpty { QuestionImage(model: model, q: q) }
                    }
                    Section("答案") { answer(q) }
                        .disabled(q.sending || q.submitted)
                    if (1...6).contains(q.type), !q.submitted {
                        Section {
                            Button("确认答案") { confirmRound = q.round; confirmSubmit = true }.disabled(q.sending)
                        }
                        aiSection(q)
                    }
                } else if model.loading.contains(id) {
                    ProgressView("正在载入题目")
                } else {
                    Button("载入题目") { model.load(id) }
                }
            } else {
                ContentUnavailableView("题目已不可用", systemImage: "questionmark.circle")
            }
        }
        .wallpaperSurface()
        .navigationTitle("课堂题目")
        .onChange(of: model.question(id)?.round, initial: true) { _, _ in
            if model.question(id)?.specification == nil { model.load(id) }
        }
        .sheet(isPresented: $settings) { NavigationStack { AISettingsView() } }
        .alert("提交课堂答案", isPresented: $confirmSubmit) {
            Button("取消", role: .cancel) {}
            Button("提交") { if let confirmRound { model.submit(id, round: confirmRound) } }
        } message: { Text("当前题目超过时限时，将使用雨课堂的补交接口。") }
        .alert("发送题目以获取 AI 建议", isPresented: $confirmAI) {
            Button("取消", role: .cancel) {}
            Button("发送并分析") {
                if let configuration, let confirmRound { model.analyze(id, round: confirmRound, config: configuration, image: useImage) }
            }
        } message: {
            Text("题干和选项将发送到 \((try? configuration?.endpoint())?.host ?? "所配置的服务")。\(useImage ? "本次还会发送课件截图。" : "")")
        }
        .alert("用建议替换当前草稿？", isPresented: $confirmApply) {
            Button("取消", role: .cancel) {}
            Button("填入草稿") { if let suggestion = model.suggestion, suggestion.questionID == id { model.apply(suggestion) } }
        }
        .alert("课堂题目", isPresented: Binding(get: { model.error != nil || localError != nil },
            set: { if !$0 { model.error = nil; localError = nil } })) {
            Button("好") { model.error = nil; localError = nil }
        } message: { Text(localError ?? model.error ?? "") }
    }

    private func status(_ q: ClassroomQuestion) -> String {
        if q.submitted { return "本机已提交成功" }
        if q.sending { return "正在提交…" }
        let now = ContinuousClock().now
        if model.finished || q.deadline.map({ now >= $0 }) == true {
            return q.eventTime > 0 ? "答题时间已结束，可尝试补交" : "答题时间已结束，缺少补交时间"
        }
        guard let deadline = q.deadline else { return "题目已开放，时限未提供" }
        return "剩余 \(max(0, now.duration(to: deadline).components.seconds)) 秒"
    }

    @ViewBuilder private func answer(_ q: ClassroomQuestion) -> some View {
        if q.isChoice {
            ForEach(Array(q.choices.enumerated()), id: \.offset) { _, choice in
                let key = choice.field("key")
                Button {
                    model.update(id, round: q.round) { current in
                        if current.draft.options.remove(key) != nil { return }
                        if current.maximum == 1 { current.draft.options = [key] }
                        else if current.draft.options.count < current.maximum { current.draft.options.insert(key) }
                    }
                } label: {
                    Label("\(key)  \(QuizAI.plain(choice.field("value")))",
                          systemImage: q.draft.options.contains(key) ? "checkmark.circle.fill" : "circle")
                }
                .disabled(key.isEmpty)
            }
        } else if q.type == 4 {
            ForEach(q.draft.blanks.indices, id: \.self) { index in
                TextField("第 \(index + 1) 空", text: Binding(
                    get: { let value = model.question(id)?.draft.blanks ?? []; return value.indices.contains(index) ? value[index] : "" },
                    set: { text in model.update(id, round: q.round) {
                        if $0.draft.blanks.indices.contains(index) { $0.draft.blanks[index] = text }
                    } }
                ))
            }
        } else if q.type == 5 {
            TextField("输入文字答案", text: Binding(get: { model.question(id)?.draft.text ?? "" },
                set: { text in model.update(id, round: q.round) { $0.draft.text = text } }), axis: .vertical)
                .lineLimit(3...10)
        } else {
            Text("暂不支持该题型")
        }
    }

    private func aiSection(_ q: ClassroomQuestion) -> some View {
        Section("AI 分析") {
            if !q.imageURLs.isEmpty { Toggle("附带题目课件截图", isOn: $useImage).disabled(model.aiBusy) }
            if model.aiBusy {
                ProgressView()
                Button("取消分析") { model.cancelAnalysis() }
            } else {
                Button("分析题目") {
                    do {
                        let config = try AIConfiguration.load()
                        if config.address.isEmpty { settings = true; return }
                        _ = try config.endpoint()
                        configuration = config
                        confirmRound = q.round
                        confirmAI = true
                    } catch { localError = error.localizedDescription }
                }.disabled(q.sending)
            }
            if let result = model.suggestion, result.questionID == id, result.round == q.round, result.signature == q.signature {
                if result.status == "answered" {
                    if !result.draft.options.isEmpty { Text("建议选项：\(q.keys.filter(result.draft.options.contains).joined(separator: "、"))") }
                    ForEach(Array(result.draft.blanks.enumerated()), id: \.offset) { index, text in
                        Text("第 \(index + 1) 空：\(text)")
                    }
                    if !result.draft.text.isEmpty { Text(result.draft.text).textSelection(.enabled) }
                    Text("模型自评：\(result.confidence.formatted(.percent.precision(.fractionLength(0))))")
                    Button("填入草稿") { confirmApply = true }.disabled(q.sending)
                } else { Text("模型未给出可填入的答案") }
                Text(result.reason).textSelection(.enabled)
            }
        }
    }
}

private struct QuestionImage: View {
    @ObservedObject var model: QuizModel
    let q: ClassroomQuestion
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit().accessibilityLabel("题目课件截图") }
            else if failed { Text("题目图片加载失败").foregroundStyle(.secondary) }
            else { ProgressView("正在加载题目图片") }
        }
        .task(id: q.round) {
            image = nil
            failed = false
            do {
                image = try await model.image(q)
                if image == nil { failed = true }
            } catch { if !Task.isCancelled { failed = true } }
        }
    }
}

struct AISettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var configuration = AIConfiguration()
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        Form {
            Section("服务配置") {
                TextField("HTTPS 接口地址", text: $configuration.address).keyboardType(.URL)
                TextField("模型名称", text: $configuration.model)
                SecureField("API Key", text: $configuration.key)
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            Section {
                Text("使用支持 JSON 模式的 OpenAI 兼容 Chat Completions 接口。只有确认分析后才发送题目。")
            }
        }
        .wallpaperSurface()
        .navigationTitle("AI 设置")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    do { try configuration.save(); dismiss() }
                    catch { self.error = error.localizedDescription }
                }
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            do { configuration = try AIConfiguration.load() }
            catch { self.error = error.localizedDescription }
        }
        .alert("AI 设置", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好") { error = nil }
        } message: { Text(error ?? "") }
    }
}
