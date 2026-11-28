import SwiftUI
import AVFoundation

@MainActor
final class ClassroomDanmu: ObservableObject {
    struct Message: Identifiable {
        let id = UUID()
        let sender: String
        let senderID: String
        let text: String
    }

    @Published private(set) var messages: [Message] = []
    @Published var sending = false
    @Published var error: String?

    @Published private var names: [String: String] = [:]
    private var requestedNames: Set<String> = []
    private var recent: [String: [Date]] = [:]
    private var sent: [String: Date] = [:]
    private let speech = AVSpeechSynthesizer()
    private let settings = UserDefaults.standard

    var enabled: Bool { settings.object(forKey: "danmuEnabled") as? Bool ?? true }

    func reset() {
        messages = []
        names = [:]
        requestedNames = []
        recent = [:]
        sent = [:]
        sending = false
        error = nil
        stopSpeech()
    }

    func stopSpeech() { speech.stopSpeaking(at: .immediate) }

    func ingest(_ event: JSON, ownID: String) -> String? {
        guard enabled else { return nil }
        let text = event.field("danmu").trimmingCharacters(in: .whitespacesAndNewlines)
        let sender = event.field("userid")
        guard !text.isEmpty, !sender.isEmpty else { return nil }
        let isOwn = sender == ownID
        messages.append(Message(sender: isOwn ? "我" : "同学", senderID: sender, text: text))
        if messages.count > 200 { messages.removeFirst(messages.count - 200) }
        if !isOwn && settings.bool(forKey: "danmuSpeakReceived") { speak("收到课堂弹幕：" + text) }
        guard !isOwn, settings.bool(forKey: "danmuAutoFollow") else { return nil }

        let now = Date()
        let cutoff = now.addingTimeInterval(-60)
        recent = recent.filter { ($0.value.last ?? .distantPast) >= cutoff }
        sent = sent.filter { $0.value >= cutoff }
        let key = text.lowercased()
        guard sent[key] == nil else { return nil }
        let threshold = min(100, max(2, settings.object(forKey: "danmuThreshold") as? Int ?? 5))
        var matches = recent[key, default: []].filter { $0 >= cutoff }
        matches.append(now)
        if matches.count < threshold {
            recent[key] = matches
            return nil
        }
        recent[key] = nil
        sent[key] = now
        return text
    }

    func senderName(for message: Message) -> String { names[message.senderID] ?? message.sender }

    func shouldLoadName(_ id: String) -> Bool {
        enabled && !id.isEmpty && requestedNames.insert(id).inserted
    }

    func saveName(_ name: String, for id: String) {
        if !name.isEmpty { names[id] = name }
    }

    func announceSent() {
        if enabled && settings.bool(forKey: "danmuSpeakSent") { speak("弹幕发送成功") }
    }

    private func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: String(text.prefix(160)))
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        speech.speak(utterance)
    }
}

struct DanmuSettingsView: View {
    @AppStorage("danmuEnabled") private var enabled = true
    @AppStorage("danmuAutoFollow") private var autoFollow = false
    @AppStorage("danmuThreshold") private var threshold = 5
    @AppStorage("danmuSpeakReceived") private var speakReceived = false
    @AppStorage("danmuSpeakSent") private var speakSent = false

    var body: some View {
        MaterialForm {
            Toggle("启用课堂弹幕", isOn: $enabled)
            if enabled {
                AppSection("自动跟随") {
                    Toggle("自动跟随发送", isOn: $autoFollow)
                    if autoFollow {
                        Stepper("相同弹幕达到 \(threshold) 条", value: $threshold, in: 2...100)
                        Text("60 秒内达到阈值时跟随发送，同一内容发送后冷却 60 秒。")
                            .font(.footnote).appTextStyle(.detail, fallback: .secondary)
                    }
                }
                AppSection("语音播报") {
                    Toggle("播报收到的弹幕", isOn: $speakReceived)
                    Toggle("播报发送成功", isOn: $speakSent)
                }
            }
        }
        .wallpaperSurface()
        .appNavigationTitle("弹幕设置")
    }
}

@MainActor
struct ClassroomDanmuView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var danmu: ClassroomDanmu
    @AppStorage("danmuEnabled") private var enabled = true
    @State private var draft = ""

    var body: some View {
        MaterialList {
            if !enabled {
                ContentUnavailableView("课堂弹幕已关闭", systemImage: "text.bubble")
            } else {
                AppSection("发送弹幕") {
                    TextField("输入弹幕", text: $draft, axis: .vertical)
                    Button("发送", systemImage: "paperplane") {
                        let text = draft
                        Task {
                            if await model.sendClassroomDanmu(text), draft == text { draft = "" }
                        }
                    }
                    .disabled(danmu.sending || !model.canSendDanmu || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let error = danmu.error { Text(error).foregroundStyle(.secondary) }
                }
                AppSection("实时弹幕") {
                    if danmu.messages.isEmpty {
                        Text("暂无弹幕").foregroundStyle(.secondary)
                    }
                    ForEach(danmu.messages.reversed()) { message in
                        LabeledContent(danmu.senderName(for: message)) {
                            Text(message.text).textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .wallpaperSurface()
        .appNavigationTitle("课堂弹幕")
    }
}
