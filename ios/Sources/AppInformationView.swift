import SwiftUI

struct AppInformationView: View {
    let licenses: Bool

    var body: some View {
        MaterialList {
            if licenses {
                AppSection("RainClassroomAssistant") {
                    Text("弹幕功能参考 · MIT License")
                    NavigationLink {
                        LicenseTextView(project: "RainClassroomAssistant")
                    } label: {
                        NavigationRowLabel { Text("查看许可证") }
                    }
                    .glassNavigationInteraction()
                }
                AppSection("ZIPFoundation") {
                    Text("ZIP 与 PPTX 导出 · MIT License")
                    NavigationLink {
                        LicenseTextView(project: "ZIPFoundation")
                    } label: {
                        NavigationRowLabel { Text("查看许可证") }
                    }
                    .glassNavigationInteraction()
                }
            } else {
                AppSection("雨课堂助手 iOS") {
                    LabeledContent("版本", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知")
                    LabeledContent("构建", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "未知")
                    Text("用于查看雨课堂课程、课件及课堂互动的 iOS 客户端。")
                    Link("项目源代码", destination: URL(string: "https://github.com/Yangst233/ykt-assistant-ios")!)
                }
            }
        }
        .wallpaperSurface()
        .appNavigationTitle(licenses ? "开放源代码许可" : "关于")
    }
}


private struct LicenseTextView: View {
    let project: String

    var body: some View {
        ScrollView {
            if let url = Bundle.main.url(forResource: project + "-License", withExtension: "txt"),
               let license = try? String(contentsOf: url, encoding: .utf8) {
                Text(license).font(.footnote.monospaced()).textSelection(.enabled).padding()
            } else {
                Text("许可证文件无法读取").padding()
            }
        }
        .wallpaperSurface()
        .appNavigationTitle(project)
    }
}
