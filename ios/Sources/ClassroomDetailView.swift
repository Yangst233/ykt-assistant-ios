import SwiftUI

struct ClassroomRoute: Hashable {
    let id: String
    let courseName: String
}

@MainActor
struct ClassroomDetailView: View {
    @ObservedObject var model: AppModel
    let route: ClassroomRoute
    @Environment(\.colorScheme) private var colorScheme
    @State private var info: JSON?
    @State private var report: JSON?
    @State private var attendanceFailed = false
    @State private var checking = false
    @State private var refresh = 0

    private var classroomName: String {
        let name = info?.field("lessonName") ?? ""
        return name.isEmpty ? (route.courseName.isEmpty ? "当前课堂" : route.courseName) : name
    }

    private var title: String {
        if !route.courseName.isEmpty { return route.courseName }
        let course = info?.field("courseName") ?? ""
        return course.isEmpty ? classroomName : course
    }

    var body: some View {
        MaterialList {
            if let lesson = model.lesson, lesson.id == route.id, let api = model.api {
                if !model.isLessonFinished {
                    Section("正在放映的课件") {
                        if model.presentation.isEmpty {
                            Text("等待教师开始放映").foregroundStyle(.secondary)
                        } else {
                            LiveSlideView(api: api, lesson: lesson, presentation: model.presentation,
                                          page: Int(model.livePage), open: model.showLiveDeck)
                                .id(model.presentation)
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(Color.clear)
                                .standaloneContainerRow()
                        }
                    }
                }
                Section("当前课堂") {
                    HStack(alignment: .firstTextBaseline) {
                        Text(classroomName).font(.headline)
                        Spacer(minLength: 8)
                        Text(connectionLabel)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(connectionForeground)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(connectionBackground, in: Capsule())
                    }
                    .accessibilityElement(children: .combine)
                    if model.connection.hasPrefix("连接中断") {
                        Text(model.connection).font(.footnote).foregroundStyle(.secondary)
                    }
                    ClassroomMetadata(info: info, report: report, attendance: attendance,
                                      refresh: { refresh += 1 }, refreshDisabled: checking)
                    NavigationLink("课堂题目") { ClassroomQuestionsView(model: model.quiz) }
                    if model.connection != "课堂已连接" && !model.isLessonFinished {
                        Button("重新连接") { model.connect() }
                    }
                }
                ClassroomPPTList(report: report) { id, title in
                    model.openClassroomPPT(id: id, title: title, lessonID: route.id)
                }
            } else {
                ContentUnavailableView("课堂连接不可用", systemImage: "person.crop.circle.badge.exclamationmark",
                                       description: Text("返回列表重新进入课堂。"))
            }
        }
        .wallpaperSurface()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: AttendanceRequest(lessonID: model.lesson?.id, refresh: refresh)) {
            guard model.lesson?.id == route.id, let api = model.api else { return }
            await loadAttendance(api)
        }
        .task(id: model.lesson?.id) {
            guard model.lesson?.id == route.id, let api = model.api else { return }
            do {
                let value = try await api.classroomReport(.info, lessonID: route.id)
                try Task.checkCancellation()
                info = value
            } catch {
                // Course metadata remains usable when the server hasn't made the report available yet.
            }
        }
    }

    private var connectionLabel: String {
        if model.connection.hasPrefix("连接中断") { return "连接中断" }
        return model.connection.isEmpty ? "连接已暂停" : model.connection
    }

    private var connectionForeground: Color {
        guard model.connection == "课堂已连接" else { return .secondary }
        return colorScheme == .dark ? Color(red: 0.63, green: 0.92, blue: 0.72)
            : Color(red: 0.08, green: 0.35, blue: 0.20)
    }

    private var connectionBackground: Color {
        guard model.connection == "课堂已连接" else { return Color(uiColor: .quaternarySystemFill) }
        return colorScheme == .dark ? Color(red: 0.12, green: 0.27, blue: 0.18)
            : Color(red: 0.87, green: 0.96, blue: 0.90)
    }

    private var attendance: String {
        if checking { return "正在查询…" }
        if attendanceFailed { return "暂无法查询" }
        guard let report else { return "正在查询…" }
        return ClassroomMetadata.status(info: info, report: report, finished: model.isLessonFinished)
    }

    private struct AttendanceRequest: Equatable {
        let lessonID: String?
        let refresh: Int
    }

    private func loadAttendance(_ api: RainAPI) async {
        checking = true
        attendanceFailed = false
        defer { checking = false }
        do {
            let data = try await api.classroomReport(.detail, lessonID: route.id)
            try Task.checkCancellation()
            report = data
        } catch {
            if !Task.isCancelled { attendanceFailed = true }
        }
    }
}
