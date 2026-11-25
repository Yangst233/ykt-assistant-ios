import SwiftUI

struct ActivityClassroomRoute: Hashable {
    let id: String
    let title: String
}

@MainActor
struct ActivityClassroomView: View {
    @ObservedObject var model: AppModel
    let route: ActivityClassroomRoute
    @State private var info: JSON?
    @State private var report: JSON?
    @State private var infoError: String?
    @State private var reportError: String?
    @State private var retry = 0

    var body: some View {
        MaterialList {
            Section("课堂信息") {
                ClassroomMetadata(info: info, report: report, attendance: attendance)
                if let infoError { Text(infoError).font(.footnote).foregroundStyle(.secondary) }
                if let reportError { Text(reportError).font(.footnote).foregroundStyle(.secondary) }
                if infoError != nil || reportError != nil {
                    Button("重试") { retry += 1 }
                }
            }
            ClassroomPPTList(report: report) { id, title in
                model.openClassroomPPT(id: id, title: title, lessonID: route.id)
            }
        }
        .wallpaperSurface()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: retry) {
            guard let api = model.api else { return }
            infoError = nil
            reportError = nil
            do {
                let value = try await api.classroomReport(.info, lessonID: route.id)
                try Task.checkCancellation()
                info = value
            } catch {
                guard !Task.isCancelled else { return }
                infoError = error.localizedDescription
            }
            do {
                let value = try await api.classroomReport(.detail, lessonID: route.id)
                try Task.checkCancellation()
                report = value
            } catch {
                if !Task.isCancelled { reportError = error.localizedDescription }
            }
        }
    }

    private var title: String {
        let name = info?.field("lessonName") ?? ""
        return name.isEmpty ? (route.title.isEmpty ? "课堂详情" : route.title) : name
    }

    private var attendance: String {
        if let report { return ClassroomMetadata.status(info: info, report: report) }
        return reportError == nil ? "正在查询…" : "暂无法查询"
    }
}

struct ClassroomMetadata: View {
    let info: JSON?
    let report: JSON?
    let attendance: String
    var refresh: (() -> Void)? = nil
    var refreshDisabled = false

    var body: some View {
        let teacher = info?.field("teacherName") ?? ""
        LabeledContent("授课教师", value: teacher.isEmpty ? "暂无信息" : teacher)
        LabeledContent("签到状态") {
            HStack(spacing: 12) {
                Text(attendance)
                if let refresh {
                    Button("刷新", action: refresh).buttonStyle(.borderless).disabled(refreshDisabled)
                }
            }
        }
        LabeledContent("上课时间") {
            if let start = Self.date(info?.field("start")) {
                Text(start, format: .dateTime)
            } else {
                Text("暂无信息")
            }
        }
        if let detail = report?["detail"] as? JSON, Self.isSigned(detail) {
            let method = detail.field("checkInName")
            if !method.isEmpty { LabeledContent("签到方式", value: method) }
        }
    }

    static func status(info: JSON?, report: JSON, finished: Bool = false) -> String {
        guard let detail = report["detail"] as? JSON else { return "暂无法查询" }
        if isSigned(detail) { return "已签到" }
        if finished || date(info?.field("end")).map({ $0 <= Date() }) == true { return "未签到" }
        return "签到待确认"
    }

    private static func isSigned(_ detail: JSON) -> Bool {
        detail.field("valid") == "1" && date(detail.field("checkInTime")) != nil
    }

    private static func date(_ raw: String?) -> Date? {
        guard let raw, let milliseconds = Double(raw), milliseconds.isFinite, milliseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }
}

struct ClassroomPPTList: View {
    let report: JSON?
    let open: (String, String) -> Void

    var body: some View {
        Section("PPT列表") {
            if let report {
                let decks = (report["presentation"] as? [JSON] ?? []).filter { !$0.field("presentationId").isEmpty }
                if decks.isEmpty {
                    Text("暂无课件").foregroundStyle(.secondary)
                }
                ForEach(decks.indices, id: \.self) { index in
                    let deck = decks[index]
                    let title = deck.field("title")
                    Button {
                        open(deck.field("presentationId"), title.isEmpty ? "课件" : title)
                    } label: {
                        NavigationRowLabel(showsArrowInNativeList: true) {
                            Label(title.isEmpty ? "课件" : title, systemImage: "slides")
                        }
                    }
                    .glassNavigationInteraction()
                }
            } else {
                Text("暂无课件信息").foregroundStyle(.secondary)
            }
        }
    }
}
