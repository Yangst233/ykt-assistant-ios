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

enum PPTPreload: Int, CaseIterable, Identifiable {
    case one = 1, five = 5, ten = 10, entire = 0

    var id: Self { self }
    var title: String { self == .entire ? "整个 PPT" : "\(rawValue) 页" }

    func pages(after page: Int, total: Int) -> [Range<Int>] {
        let forward = (page + 1)..<total
        if self == .entire { return [forward, 0..<page] }
        return [forward.prefix(rawValue)]
    }
}

@MainActor
final class AppAppearance: ObservableObject {
    @Published var theme = AppTheme(rawValue: UserDefaults.standard.string(forKey: "appTheme") ?? "") ?? .system {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: "appTheme") }
    }
    @Published var containerMaterial = ContainerMaterial(
        rawValue: UserDefaults.standard.string(forKey: "containerMaterial") ?? ""
    ) ?? .standard {
        didSet { UserDefaults.standard.set(containerMaterial.rawValue, forKey: "containerMaterial") }
    }
    @Published var glassDensity = UserDefaults.standard.object(forKey: "glassDensity") as? Double ?? 0.35 {
        didSet { UserDefaults.standard.set(glassDensity, forKey: "glassDensity") }
    }
    @Published var wallpaperOverlayOpacity = UserDefaults.standard.object(forKey: "wallpaperOverlayOpacity") as? Double ?? 0.58 {
        didSet { UserDefaults.standard.set(wallpaperOverlayOpacity, forKey: "wallpaperOverlayOpacity") }
    }
    @Published var pptPreload = PPTPreload(rawValue: UserDefaults.standard.object(forKey: "pptPreloadPageCount") as? Int ?? 1) ?? .one {
        didSet { UserDefaults.standard.set(pptPreload.rawValue, forKey: "pptPreloadPageCount") }
    }
    @Published var cachePPT = UserDefaults.standard.object(forKey: "cachePPT") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(cachePPT, forKey: "cachePPT")
            if !cachePPT { pptCache.removeAllObjects() }
        }
    }
    private let pptCache = NSCache<NSString, UIImage>()
    @Published private(set) var wallpaper: UIImage?

    init() {
        pptCache.totalCostLimit = 64 * 1024 * 1024
        pptCache.countLimit = 24
        if let url = try? Self.wallpaperURL(), let data = try? Data(contentsOf: url) {
            wallpaper = UIImage(data: data)
        }
    }

    func cachedPPTImage(_ key: String) -> UIImage? {
        guard cachePPT else { return nil }
        return pptCache.object(forKey: key as NSString)
    }

    func cachePPTImage(_ image: UIImage, key: String) {
        guard cachePPT, let pixels = image.cgImage else { return }
        let (cost, overflow) = pixels.bytesPerRow.multipliedReportingOverflow(by: pixels.height)
        guard !overflow, cost <= pptCache.totalCostLimit else { return }
        pptCache.setObject(image, forKey: key as NSString, cost: cost)
    }

    func removeCachedPPTImage(_ key: String) {
        pptCache.removeObject(forKey: key as NSString)
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

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var hidesScrollBackground: Bool {
        if appearance.wallpaper != nil { return true }
        if #available(iOS 18.0, *) {
            return appearance.containerMaterial != .standard && !reduceTransparency && contrast != .increased
        }
        return false
    }

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(hidesScrollBackground ? .hidden : .automatic)
            .background {
                if let image = appearance.wallpaper {
                    GeometryReader { bounds in
                        Image(uiImage: image).resizable().scaledToFill()
                            .frame(width: bounds.size.width, height: bounds.size.height)
                            .clipped()
                    }
                    .overlay(Color(uiColor: .systemBackground).opacity(appearance.wallpaperOverlayOpacity))
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
                } else if hidesScrollBackground {
                    Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
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
            SettingsPickerRow("主题", value: appearance.theme.title, selection: $appearance.theme) {
                ForEach(AppTheme.allCases) { theme in
                    Text(theme.title).tag(theme)
                }
            }
            .ownsGlassRowLayout()
            SettingsPickerRow("容器材质", value: appearance.containerMaterial.title, selection: $appearance.containerMaterial) {
                ForEach(ContainerMaterial.allCases) { material in
                    Text(material.title).tag(material)
                }
            }
            .ownsGlassRowLayout()
            if appearance.containerMaterial != .standard {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("玻璃浓度", value: appearance.glassDensity.formatted(.percent.precision(.fractionLength(0))))
                    Slider(value: $appearance.glassDensity, in: 0...1, step: 0.01) {
                        Text("玻璃浓度")
                    }
                }
                .padding(.vertical, 6)
            }
            PhotosPicker(selection: $selection, matching: .images) {
                Label(appearance.wallpaper == nil ? "选择壁纸" : "更换壁纸", systemImage: "photo")
            }
            .disabled(loading)
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
            if loading { ProgressView("正在载入壁纸") }
            if appearance.wallpaper != nil {
                VStack(alignment: .leading) {
                    LabeledContent("遮罩不透明度", value: appearance.wallpaperOverlayOpacity.formatted(.percent.precision(.fractionLength(0))))
                    Slider(value: $appearance.wallpaperOverlayOpacity, in: 0...1, step: 0.01) {
                        Text("遮罩不透明度")
                    }
                }
                Button("移除壁纸", role: .destructive) {
                    do { try appearance.removeWallpaper() }
                    catch { self.error = error.localizedDescription }
                }
                .disabled(loading)
            }
        }

    }
}
