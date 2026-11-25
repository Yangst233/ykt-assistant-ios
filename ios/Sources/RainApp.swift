import SwiftUI
import AVFoundation
import VisionKit
import UniformTypeIdentifiers

@main
@MainActor
struct RainApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            Home(model: model)
                .onChange(of: phase, initial: true) { _, new in model.phase(new) }
        }
    }
}

@MainActor
struct Home: View {
    @ObservedObject var model: AppModel
    @State private var input = ""
    @State private var scan = false
    @State private var course = ""
    @State private var type = ""

    var body: some View {
        TabView {
            NavigationStack { classes.navigationTitle("课程") }
                .tabItem { Label("课程", systemImage: "book") }
            NavigationStack { activities.navigationTitle("动态") }
                .tabItem { Label("动态", systemImage: "list.bullet.rectangle") }
            NavigationStack { settings.navigationTitle("账号") }
                .tabItem { Label("账号", systemImage: "person.crop.circle") }
        }
        .safeAreaInset(edge: .top) {
            if model.busy {
                HStack {
                    ProgressView()
                    Spacer()
                    Button("取消") { model.cancel(); model.qr = nil }
                }
                .padding(.horizontal)
                .background(.bar)
            }
        }
        .sheet(isPresented: $scan) {
            Scanner { result in
                scan = false
                switch result {
                case .success(let value): input = value; model.enter(value)
                case .failure(let error): model.error = error.localizedDescription
                }
            }
        }
        .sheet(item: $model.deck) { deck in
            if let api = model.api { DeckView(deck: deck, api: api) }
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

    private func requestScanner() {
        Task {
            guard await AVCaptureDevice.requestAccess(for: .video), DataScannerViewController.isAvailable else {
                model.error = "相机不可用，请检查相机权限或手动输入课堂 ID"
                return
            }
            if model.selected != nil { scan = true }
        }
    }

    private var classes: some View {
        List {
            if model.selected == nil {
                ContentUnavailableView("请先登录", systemImage: "person.crop.circle.badge.exclamationmark")
            } else {
                if let lesson = model.lesson {
                    Section("当前课堂") {
                        Text("课堂 " + lesson.id)
                        Text(model.connection.isEmpty ? "课堂连接已暂停" : model.connection)
                        if !model.livePage.isEmpty { Text("播放页：\(model.livePage)") }
                        if !model.presentation.isEmpty {
                            Button("查看实时课件") {
                                model.openDeck(id: model.presentation, title: "实时课件", historical: nil)
                            }
                        }
                        Button("重新连接") { model.connect() }
                        Button("离开课堂", role: .destructive) { model.leave() }
                    }
                }
                Section("入课") {
                    TextField("课堂 ID 或课堂二维码链接", text: $input, axis: .vertical)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("查看课堂") { model.enter(input) }.disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if DataScannerViewController.isSupported {
                        Button("扫描课堂二维码", systemImage: "qrcode.viewfinder") { requestScanner() }
                    }
                }
                Section("正在上课") {
                    if model.live.isEmpty { Text("暂无正在上课的课堂") }
                    ForEach(model.live.indices, id: \.self) { index in
                        let row = model.live[index]
                        let metadata = model.courses.first { $0.field("course_id") == row.field("courseId") }
                        Button {
                            model.enter(row.field("lessonId"))
                        } label: {
                            VStack(alignment: .leading) {
                                Text(metadata?.field("course_name").nonempty ?? "课堂 " + row.field("lessonId"))
                                Text(row.field("lessonId")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .contextMenu {
                            Button("复制课堂 ID") { UIPasteboard.general.string = row.field("lessonId") }
                        }
                    }
                }
                Section("我的课程") {
                    ForEach(model.courses.indices, id: \.self) { index in
                        let row = model.courses[index]
                        VStack(alignment: .leading) {
                            Text(row.field("course_name").nonempty ?? row.field("course_id"))
                            if let room = row.field("classroom_name").nonempty { Text(room).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
        }
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
            Section("已保存账号") {
                ForEach(model.accounts.filter { $0.service == model.service }) { account in
                    Button {
                        model.select(account)
                    } label: {
                        HStack {
                            Text(account.name.nonempty ?? account.userID)
                            Spacer()
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
        }
    }
}

private extension String {
    var nonempty: String? { isEmpty ? nil : self }
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
