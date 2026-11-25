import SwiftUI
import PhotosUI
import ImageIO

enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: Self { self }
    var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    var scheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

@MainActor
final class AppAppearance: ObservableObject {
    @Published var theme = AppTheme(rawValue: UserDefaults.standard.string(forKey: "appTheme") ?? "") ?? .system {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: "appTheme") }
    }
    @Published private(set) var wallpaper: UIImage?

    init() {
        if let url = try? Self.wallpaperURL(), let data = try? Data(contentsOf: url) {
            wallpaper = UIImage(data: data)
        }
    }

    private static func wallpaperURL() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true).appendingPathComponent("wallpaper.jpg")
    }

    func setWallpaper(_ item: PhotosPickerItem) async throws {
        guard let bytes = try await item.loadTransferable(type: Data.self) else {
            throw RainError.invalid("无法读取选中的图片")
        }
        let jpeg = try await Self.wallpaperJPEG(bytes)
        try Task.checkCancellation()
        guard let image = UIImage(data: jpeg) else { throw RainError.invalid("壁纸图片") }
        try jpeg.write(to: Self.wallpaperURL(), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        wallpaper = image
    }

    func removeWallpaper() throws {
        let url = try Self.wallpaperURL()
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        wallpaper = nil
    }

    nonisolated private static func wallpaperJPEG(_ bytes: Data) async throws -> Data {
        guard bytes.count <= 64 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let bitmap = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048
              ] as CFDictionary),
              let jpeg = UIImage(cgImage: bitmap).jpegData(compressionQuality: 0.88) else {
            throw RainError.invalid("无法处理此壁纸图片")
        }
        return jpeg
    }
}

private struct WallpaperSurface: ViewModifier {
    @EnvironmentObject private var appearance: AppAppearance

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(appearance.wallpaper == nil ? .automatic : .hidden)
            .background {
                if let image = appearance.wallpaper {
                    GeometryReader { bounds in
                        Image(uiImage: image).resizable().scaledToFill()
                            .frame(width: bounds.size.width, height: bounds.size.height)
                            .clipped()
                    }
                    .overlay(Color(uiColor: .systemBackground).opacity(0.58))
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
                }
            }
    }
}

extension View {
    func wallpaperSurface() -> some View { modifier(WallpaperSurface()) }
}

struct AppearanceSettings: View {
    @EnvironmentObject private var appearance: AppAppearance
    @State private var selection: PhotosPickerItem?
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        Section("外观") {
            Picker("主题", selection: $appearance.theme) {
                ForEach(AppTheme.allCases) { theme in
                    Text(theme.title).tag(theme)
                }
            }
            PhotosPicker(selection: $selection, matching: .images) {
                Label(appearance.wallpaper == nil ? "选择壁纸" : "更换壁纸", systemImage: "photo")
            }
            .disabled(loading)
            if loading { ProgressView("正在载入壁纸") }
            if appearance.wallpaper != nil {
                Button("移除壁纸", role: .destructive) {
                    do { try appearance.removeWallpaper() }
                    catch { self.error = error.localizedDescription }
                }
                .disabled(loading)
            }
        }
        .task(id: selection) {
            guard let selection else { return }
            loading = true
            defer {
                if !Task.isCancelled {
                    loading = false
                    self.selection = nil
                }
            }
            do { try await appearance.setWallpaper(selection) }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
        .alert("壁纸", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好") { error = nil }
        } message: { Text(error ?? "") }
    }
}
