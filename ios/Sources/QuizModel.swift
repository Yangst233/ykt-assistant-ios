import SwiftUI

struct QuizDraft: Equatable {
    var options: Set<String> = []
    var blanks: [String] = []
    var text = ""
    var pictures: [String] = []
}

struct ClassroomQuestion: Identifiable {
    let id: String
    var presentation: String
    var eventTime: Int64
    var deadline: ContinuousClock.Instant?
    var round = UUID()
    var specification: JSON?
    var slide: JSON?
    var draft = QuizDraft()
    var sending = false
    var submitted = false

    var type: Int { Int(specification?.field("problemType") ?? "") ?? 0 }
    var choices: [JSON] { specification?["options"] as? [JSON] ?? [] }
    var keys: [String] { choices.map { $0.field("key") }.filter { !$0.isEmpty } }
    var isChoice: Bool { (1...3).contains(type) || type == 6 }
    var blankCount: Int { (specification?["blanks"] as? [Any])?.count ?? 0 }
    var maximum: Int {
        if type == 1 || type == 6 { return 1 }
        if type == 3 { return max(1, Int(specification?.field("pollingCount") ?? "") ?? 1) }
        return keys.count
    }
    var imageURLs: [String] {
        guard let slide else { return [] }
        return ["cover", "coverAlt", "thumbnail"].map(slide.field).filter { !$0.isEmpty }
    }
    var signature: Data? {
        guard let specification else { return nil }
        return try? JSONSerialization.data(withJSONObject: specification, options: .sortedKeys)
    }

    func submission(finished: Bool, wall: Int64, now: ContinuousClock.Instant) throws -> (path: String, body: JSON) {
        guard specification != nil, !sending, !submitted else { throw RainError.invalid("题目尚未加载或已提交") }
        let result: Any
        if isChoice {
            let selected = keys.filter(draft.options.contains)
            guard !selected.isEmpty, Set(selected) == draft.options, selected.count <= maximum else {
                throw RainError.invalid("请选择有效答案")
            }
            result = selected
        } else if type == 4 {
            guard (1...100).contains(blankCount), draft.blanks.count == blankCount,
                  draft.blanks.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw RainError.invalid("请填写每个空格")
            }
            result = draft.blanks
        } else if type == 5 {
            guard !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.pictures.isEmpty else {
                throw RainError.invalid("请填写文字或添加答案图片")
            }
            let pictures = draft.pictures.map { ["pic": $0, "thumb": $0 + "?imageView2/2/w/568"] }
            result = ["content": draft.text, "pics": pictures, "videos": []] as JSON
        } else { throw RainError.invalid("暂不支持该题型") }
        let retry = finished || deadline.map { now >= $0 } == true
        guard !retry || eventTime > 0 else { throw RainError.invalid("缺少题目原始时间，无法补交") }
        var body: JSON = ["problemId": id, "problemType": type, "dt": retry ? eventTime : wall, "result": result]
        if retry {
            body["retry_times"] = NSNull()
            return ("/api/v3/lesson/problem/retry", ["problems": [body]])
        }
        return ("/api/v3/lesson/problem/answer", body)
    }
}

@MainActor
final class QuizModel: ObservableObject {
    @Published private(set) var questions: [ClassroomQuestion] = []
    @Published private(set) var finished = false
    @Published var error: String?
    @Published private(set) var loading: Set<String> = []
    @Published private(set) var aiBusy = false
    @Published private(set) var suggestion: QuizSuggestion?
    private var api: RainAPI?
    private var lesson: Lesson?
    private var tasks: [String: Task<Void, Never>] = [:]
    private var extensions: Set<String> = []
    private var activeID = ""
    private var epoch = UUID()
    private let clock = ContinuousClock()
    static var wallTime: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    func bind(api: RainAPI? = nil, lesson: Lesson? = nil) {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        epoch = UUID()
        self.api = api
        self.lesson = lesson
        questions = []
        loading = []
        extensions = []
        finished = false
        activeID = ""
        error = nil
        suggestion = nil
        aiBusy = false
    }

    func ingest(_ event: JSON, presentation: String) {
        for item in event["timeline"] as? [JSON] ?? [] where item.field("type") == "problem" {
            let pres = item.field("pres")
            open(item, presentation: pres.isEmpty ? presentation : pres)
        }
        let op = event.field("op")
        if op == "lessonfinished" || event.field("message") == "lesson finished" { finished = true }
        guard let problem = event["problem"] as? JSON else { return }
        if op == "unlockproblem" { open(problem, presentation: presentation) }
        if op == "extendtime" {
            let prob = problem.field("prob")
            let id = prob.isEmpty ? activeID : prob
            let stamp = Int64(problem.field("dt")) ?? 0
            guard let index = questions.firstIndex(where: { $0.id == id }),
                  let extra = Int64(problem.field("extend")), (1...31_536_000).contains(extra),
                  let deadline = questions[index].deadline else { return }
            if stamp > 0, !extensions.insert("\(id):\(stamp):\(extra)").inserted { return }
            questions[index].deadline = max(clock.now, deadline) + .seconds(extra)
        }
    }

    private func open(_ event: JSON, presentation: String) {
        let id = event.field("prob")
        guard !id.isEmpty else { return }
        let stamp = max(0, Int64(event.field("dt")) ?? 0)
        let limit = Int64(event.field("limit")) ?? 0
        if let index = questions.firstIndex(where: { $0.id == id }) {
            let previous = questions[index]
            if stamp == 0 || stamp <= previous.eventTime {
                if previous.presentation.isEmpty { questions[index].presentation = presentation }
                return
            }
            questions.remove(at: index)
        }
        var question = ClassroomQuestion(id: id, presentation: presentation, eventTime: stamp)
        if (1...31_536_000).contains(limit) {
            let age = stamp == 0 ? 0 : max(0, Self.wallTime - stamp)
            question.deadline = clock.now + .milliseconds(max(0, limit * 1000 - age))
        }
        questions.append(question)
        activeID = id
    }

    func question(_ id: String) -> ClassroomQuestion? { questions.first { $0.id == id } }

    func batchSource() async throws -> (RainAPI, String, [ArchivedQuestion]) {
        guard let api, let lesson else { throw RainError.invalid("请先进入课堂") }
        let scope = epoch
        let opened = questions
        var pages: [String: [JSON]] = [:]
        var results: [ArchivedQuestion] = []
        for (offset, q) in opened.enumerated() where !q.presentation.isEmpty {
            try Task.checkCancellation()
            guard epoch == scope else { throw CancellationError() }
            if pages[q.presentation] == nil {
                let data = try await api.request("/api/v3/lesson/presentation/fetch",
                    query: [.init(name: "presentation_id", value: q.presentation)], bearer: lesson.bearer).0.object("data")
                guard data["id"] == nil || data.field("id") == q.presentation else { throw RainError.invalid("题目课件关联") }
                pages[q.presentation] = try data.rows("slides")
            }
            guard let slide = pages[q.presentation]?.first(where: {
                ($0["problem"] as? JSON)?.field("problemId") == q.id
            }), let spec = slide["problem"] as? JSON else { continue }
            var question = q
            question.specification = spec
            question.slide = slide
            let id = "live:\(lesson.id):\(q.presentation):\(q.id)"
            results.append(.init(id: id, title: "课堂 \(lesson.id) · 题目 \(offset + 1)", question: question))
        }
        try Task.checkCancellation()
        guard epoch == scope else { throw CancellationError() }
        return (api, api.service.rawValue + ":" + api.userID, results)
    }

    func update(_ id: String, round: UUID, _ change: (inout ClassroomQuestion) -> Void) {
        guard let index = questions.firstIndex(where: { $0.id == id && $0.round == round }) else { return }
        change(&questions[index])
    }

    func load(_ id: String) {
        let key = "load:" + id
        guard let api, let lesson, let question = question(id), tasks[key] == nil else { return }
        guard !question.presentation.isEmpty else { error = "尚未收到题目关联的课件，请重新连接课堂。"; return }
        let scope = epoch
        loading.insert(id)
        tasks[key] = Task {
            defer { if epoch == scope { tasks[key] = nil; loading.remove(id) } }
            do {
                let data = try await api.request("/api/v3/lesson/presentation/fetch",
                    query: [.init(name: "presentation_id", value: question.presentation)], bearer: lesson.bearer).0.object("data")
                guard data["id"] == nil || data.field("id") == question.presentation else { throw RainError.invalid("题目课件关联") }
                let slides = try data.rows("slides")
                guard let slide = slides.first(where: { ($0["problem"] as? JSON)?.field("problemId") == id }),
                      let specification = slide["problem"] as? JSON else { throw RainError.invalid("课件内未找到该题") }
                try Task.checkCancellation()
                update(id, round: question.round) { current in
                    let next = ClassroomQuestion(id: id, presentation: current.presentation, eventTime: current.eventTime,
                                                 specification: specification)
                    if current.signature != next.signature {
                        current.draft = QuizDraft(blanks: Array(repeating: "", count: min(next.blankCount, 100)))
                    }
                    current.specification = specification
                    current.slide = slide
                }
            } catch { if epoch == scope && !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    
    func submit(_ id: String, round: UUID) {
        guard let api, let lesson, let q = question(id), q.round == round else { return }
        let key = "submit:" + id
        guard tasks[key] == nil else { return }
        do {
            let payload = try q.submission(finished: finished, wall: Self.wallTime, now: clock.now)
            update(id, round: round) { $0.sending = true }
            let scope = epoch
            tasks[key] = Task {
                defer {
                    if epoch == scope { tasks[key] = nil; update(id, round: round) { $0.sending = false } }
                }
                do {
                    let response = try await api.request(payload.path, body: payload.body, bearer: lesson.bearer).0
                    guard response.field("code") == "0" else { throw RainError.invalid("未收到明确的提交成功确认，请核对后再重试") }
                    try Task.checkCancellation()
                    update(id, round: round) { $0.submitted = true }
                } catch { if epoch == scope && !Task.isCancelled { self.error = error.localizedDescription } }
            }
        } catch { self.error = error.localizedDescription }
    }

    func analyze(_ id: String, round: UUID, config: AIConfiguration, image: Bool) {
        guard let api, let q = question(id), q.round == round, !q.sending, !q.submitted, tasks["ai"] == nil else { return }
        let scope = epoch
        suggestion = nil
        aiBusy = true
        tasks["ai"] = Task {
            defer { if epoch == scope { tasks["ai"] = nil; aiBusy = false } }
            do {
                let photo = image ? try await api.slideImage(q.imageURLs) : nil
                let result = try await QuizAI.analyze(q, configuration: config, image: photo)
                try Task.checkCancellation()
                guard let current = question(id), current.round == q.round, current.signature == q.signature,
                      !current.submitted, !current.sending else { throw RainError.invalid("题目已变化，请重新分析") }
                suggestion = result
            } catch { if epoch == scope && !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }

    func image(_ q: ClassroomQuestion) async throws -> UIImage? {
        guard let api else { return nil }
        let bytes = try await api.slideImage(q.imageURLs)
        try Task.checkCancellation()
        return UIImage(data: bytes)
    }

    func cancelAnalysis() { tasks["ai"]?.cancel() }

    func uploadPicture(_ data: Data, id: String, round: UUID) async throws {
        guard let api, let q = question(id), q.round == round, q.type == 5,
              !q.submitted, !q.sending, q.draft.pictures.count < 6 else { return }
        let scope = epoch
        let url = try await api.uploadAnswerImage(data)
        try Task.checkCancellation()
        guard epoch == scope else { return }
        update(id, round: round) {
            if !$0.submitted, !$0.sending, $0.draft.pictures.count < 6 { $0.draft.pictures.append(url) }
        }
    }

    func apply(_ suggestion: QuizSuggestion) {
        guard let q = question(suggestion.questionID), q.round == suggestion.round, q.signature == suggestion.signature,
              !q.submitted, !q.sending, suggestion.status == "answered" else { return }
        update(q.id, round: q.round) {
            var draft = suggestion.draft
            draft.pictures = $0.draft.pictures
            $0.draft = draft
        }
    }
}
