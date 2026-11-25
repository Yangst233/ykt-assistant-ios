import SwiftUI
import AVFoundation
import VisionKit
import UniformTypeIdentifiers

@main
@MainActor
struct RainApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var appearance = AppAppearance()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            Home(model: model)
                .environmentObject(appearance)
                .preferredColorScheme(appearance.theme.scheme)
                .onChange(of: phase, initial: true) { _, new in model.phase(new) }
        }
    }
}

@MainActor
struct Home: View {
    @ObservedObject var model: AppModel
    private enum HomeTab: Hashable { case live, all, activities, account }

    @State private var tab: HomeTab = .live
    @State private var classroomPath: [ClassroomRoute] = []
    @State private var showingJoin = false
    @State private var pendingJoin: String?
    @State private var classroomSearch = ""
    @State private var course = ""
    @State private var type = ""

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack(path: $classroomPath) {
                liveClassrooms
                    .navigationDestination(for: ClassroomRoute.self) { route in
                        ClassroomDetailView(model: model, route: route)
                    }
                    .navigationTitle("正在上课")
                    .toolbar {
                        requestToolbar
                        if model.selected != nil {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("加入课堂", systemImage: "plus") { showingJoin = true }
                            }
                        }
                    }
            }
            .tabItem { Label("正在上课", systemImage: "play.circle") }
            .tag(HomeTab.live)
            NavigationStack {
                allClassrooms.navigationTitle("所有课堂").toolbar { requestToolbar }
            }
            .tabItem { Label("所有课堂", systemImage: "books.vertical") }
            .tag(HomeTab.all)
            NavigationStack {
                activities.navigationTitle("动态").toolbar { requestToolbar }
            }
            .tabItem { Label("动态", systemImage: "list.bullet.rectangle") }
            .tag(HomeTab.activities)
            NavigationStack {
                settings.navigationTitle("我的").toolbar { requestToolbar }
            }
            .tabItem { Label("我的", systemImage: "person.crop.circle") }
            .tag(HomeTab.account)
        }
        .onChange(of: model.classroomEntry) { _, _ in
            guard let lesson = model.lesson else { return }
            let row = model.live.first { $0.field("lessonId") == lesson.id }
            classroomPath = [ClassroomRoute(id: lesson.id, courseName: row.map(courseName) ?? "")]
            tab = .live
        }
        .onChange(of: model.selected) { _, _ in classroomPath = [] }
        .sheet(isPresented: $showingJoin, onDismiss: {
            if let value = pendingJoin {
                pendingJoin = nil
                if model.selected != nil { model.enter(value) }
            }
        }) {
            JoinClassroomSheet { value in
                pendingJoin = value
                showingJoin = false
            }
        }
        .sheet(item: $model.deck) { deck in
            if let api = model.api {
                if deck.live == nil { DeckView(deck: deck, api: api) }
                else { LiveDeckReader(model: model, api: api, initialDeck: deck) }
            }
        }
        .alert("雨课堂", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("好") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .confirmationDialog("未找到课堂凭证，是否签到并进入课堂？",
            isPresented: Binding(get: { model.pendingLesson != nil }, set: { if !$0 { model.pendingLesson = nil } }),
            titleVisibility: .visible, presenting: model.pendingLesson) { id in
                Button("签到并进入课堂") { model.confirm(id) }
                Button("取消", role: .cancel) { model.pendingLesson = nil }
            }
    }

    @ToolbarContentBuilder private var requestToolbar: some ToolbarContent {
        if model.busy {
            ToolbarItem(placement: .topBarTrailing) {
                ProgressView().accessibilityLabel("正在加载")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("取消") { model.cancel(); model.qr = nil }
            }
        }
    }

    private func courseName(_ row: JSON) -> String {
        let course = model.courses.first { $0.field("course_id") == row.field("courseId") }
        return course?.field("course_name").nonempty ?? row.field("courseName")
    }

    private var liveClassrooms: some View {
        List {
            if model.selected == nil {
                ContentUnavailableView("请先登录", systemImage: "person.crop.circle.badge.exclamationmark")
            } else if model.live.isEmpty && !model.busy {
                ContentUnavailableView("暂无正在上课的课程", systemImage: "play.circle")
            } else {
                ForEach(model.live.indices, id: \.self) { index in
                    let row = model.live[index]
                    let lessonID = row.field("lessonId")
                    Button {
                        model.enter(lessonID)
                    } label: {
                        HStack {
                            Text(courseName(row).nonempty ?? "课堂 " + lessonID)
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                    }
                    .contextMenu {
                        Button("复制课堂 ID") { UIPasteboard.general.string = lessonID }
                    }
                }
            }
        }
        .wallpaperSurface()
        .refreshable { model.run { try await model.loadCourses() } }
    }

    private var allClassrooms: some View {
        List {
            if model.selected == nil {
                ContentUnavailableView("请先登录", systemImage: "person.crop.circle.badge.exclamationmark")
            } else {
                let query = classroomSearch.trimmingCharacters(in: .whitespacesAndNewlines)
                let matches = model.courses.indices.filter { index in
                    let row = model.courses[index]
                    return query.isEmpty || ["course_name", "classroom_name", "course_id"]
                        .contains { row.field($0).localizedStandardContains(query) }
                }
                if matches.isEmpty && !model.busy {
                    if query.isEmpty {
                        ContentUnavailableView("暂无课程", systemImage: "books.vertical")
                    } else {
                        ContentUnavailableView.search(text: query)
                    }
                }
                ForEach(matches, id: \.self) { index in
                    let row = model.courses[index]
                    VStack(alignment: .leading) {
                        Text(row.field("course_name").nonempty ?? row.field("course_id"))
                        if let room = row.field("classroom_name").nonempty { Text(room).foregroundStyle(.secondary) }
                    }
                }
            }
        }
        .wallpaperSurface()
        .searchable(text: $classroomSearch, prompt: "搜索课程或班级")
        .onChange(of: model.selected) { _, _ in classroomSearch = "" }
        .refreshable { model.run { try await model.loadCourses() } }
    }

    private var activities: some View {
        List {
            if model.selected == nil {
                ContentUnavailableView("请先登录", systemImage: "person.crop.circle")
            } else {
                let courses = Set(model.feed.map { $0.field("courseName") }.filter { !$0.isEmpty }).sorted()
                Section {
                    Picker("课程", selection: $course) {
                        Text("全部").tag("")
                        ForEach(courses, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("类型", selection: $type) {
                        Text("全部").tag("")
                        Text("课堂").tag("14")
                        Text("作业").tag("5")
                    }
                    Button("刷新动态") { model.run { try await model.loadFeed(reset: true) } }
                }
                if let report = model.report { reportSection(report) }
                ForEach(model.feed.indices, id: \.self) { index in
                    let item = model.feed[index]
                    if (type.isEmpty || item.field("coursewareType") == type)
                        && (course.isEmpty || item.field("courseName") == course) {
                        if item.field("coursewareType") == "14" {
                            Button { model.loadReport(item.field("coursewareId")) } label: { activityLabel(item) }
                        } else {
                            activityLabel(item)
                        }
                    }
                }
                if model.canPage && !model.feed.isEmpty {
                    Button("加载更多") { model.run { try await model.loadFeed(reset: false) } }
                }
            }
        }
        .wallpaperSurface()
        .onChange(of: model.selected) { _, _ in course = ""; type = "" }
        .refreshable { model.run { try await model.loadFeed(reset: true) } }
    }

    private func activityLabel(_ row: JSON) -> some View {
        VStack(alignment: .leading) {
            Text(row.field("coursewareTitle").nonempty ?? row.field("courseName"))
            Text(row.field("courseName")).font(.caption).foregroundStyle(.secondary)
            if let ms = Double(row.field("createTime")) {
                Text(Date(timeIntervalSince1970: ms / 1000), format: .dateTime)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func reportSection(_ report: JSON) -> some View {
        let info = (report["info"] as? JSON) ?? [:]
        let detail = (report["detail"] as? JSON) ?? [:]
        let attendance = (detail["detail"] as? JSON) ?? [:]
        let decks = (detail["presentation"] as? [JSON]) ?? []
        return Section(info.field("lessonName").nonempty ?? "课堂报告") {
            Text(info.field("teacherName"))
            if attendance.field("valid") == "1", let ms = Double(attendance.field("checkInTime")), ms > 0 {
                Label("已签到", systemImage: "checkmark.circle")
                Text(Date(timeIntervalSince1970: ms / 1000), format: .dateTime)
                if let channel = attendance.field("checkInName").nonempty { Text(channel) }
            } else if let end = Double(info.field("end")), end > 0, end / 1000 <= Date().timeIntervalSince1970 {
                Text("未签到")
            } else {
                Text("签到待确认")
            }
            ForEach(decks.indices, id: \.self) { index in
                let deck = decks[index]
                let title = deck.field("title").nonempty ?? "课件"
                Button(title) {
                    model.openDeck(id: deck.field("presentationId"), title: title, historical: report.field("id"))
                }
            }
        }
    }

    private var settings: some View {
        List {
            Picker("服务", selection: Binding(get: { model.service }, set: model.switchService)) {
                ForEach(Service.allCases) { Text($0.title).tag($0) }
            }
            NavigationLink("AI 设置") { AISettingsView() }
            Section("已保存账号") {
                ForEach(model.accounts) { account in
                    Button {
                        model.select(account)
                    } label: {
                        HStack {
                            Text(account.name.nonempty ?? account.userID)
                            Spacer()
                            Text(account.service.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(.quaternary, in: Capsule())
                            if model.selected == account.id { Image(systemName: "checkmark") }
                        }
                    }
                    .swipeActions {
                        Button("移除", role: .destructive) { model.delete(account) }
                    }
                }
            }
            Section {
                Button("生成登录二维码", systemImage: "qrcode") { model.login() }
                if let qr = model.qr {
                    Image(uiImage: qr).interpolation(.none).resizable().scaledToFit()
                        .padding(20).background(.white)
                        .accessibilityLabel("雨课堂登录二维码")
                }
                if let status = model.loginStatus { Text(status).foregroundStyle(.secondary) }
            }
            AppearanceSettings()
        }
        .wallpaperSurface()
    }
}

private extension String {
    var nonempty: String? { isEmpty ? nil : self }
}

@MainActor
private struct JoinClassroomSheet: View {
    let onJoin: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var scanning = false
    @State private var error: String?
    @State private var requestingCamera = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("课堂 ID 或课堂二维码链接", text: $input, axis: .vertical)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if DataScannerViewController.isSupported {
                    Button("扫描课堂二维码", systemImage: "qrcode.viewfinder") {
                        requestingCamera = true
                        Task {
                            defer { requestingCamera = false }
                            if await AVCaptureDevice.requestAccess(for: .video), DataScannerViewController.isAvailable {
                                scanning = true
                            } else {
                                error = "相机不可用，请检查相机权限或手动输入课堂 ID"
                            }
                        }
                    }
                    .disabled(requestingCamera)
                }
            }
            .wallpaperSurface()
            .navigationTitle("加入课堂")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("查看课堂") { onJoin(input) }
                        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationDestination(isPresented: $scanning) {
                Scanner { result in
                    switch result {
                    case .success(let value): onJoin(value)
                    case .failure(let failure):
                        scanning = false
                        error = failure.localizedDescription
                    }
                }
                .navigationTitle("扫描课堂二维码")
                .navigationBarTitleDisplayMode(.inline)
            }
            .alert("加入课堂", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好") { error = nil }
            } message: { Text(error ?? "") }
        }
    }
}

struct Scanner: UIViewControllerRepresentable {
    let complete: (Result<String, Error>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(complete: complete) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])])
        scanner.delegate = context.coordinator
        do { try scanner.startScanning() }
        catch {
            let coordinator = context.coordinator
            DispatchQueue.main.async { coordinator.finish(.failure(error)) }
        }
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let complete: (Result<String, Error>) -> Void
        var delivered = false

        init(complete: @escaping (Result<String, Error>) -> Void) { self.complete = complete }

        func finish(_ result: Result<String, Error>) {
            guard !delivered else { return }
            delivered = true
            complete(result)
        }

        func dataScanner(_ scanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems {
                if case .barcode(let barcode) = item, let value = barcode.payloadStringValue {
                    scanner.stopScanning()
                    finish(.success(value))
                    return
                }
            }
        }

        func dataScanner(_ scanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            finish(.failure(error))
        }
    }
}
