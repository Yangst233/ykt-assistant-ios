import SwiftUI

enum AppTextRole: String, CaseIterable, Identifiable {
    case largeTitle, smallTitle, contentTitle, body, secondary, detail, action

    var id: Self { self }

    var title: String {
        switch self {
        case .largeTitle: "导航大标题"
        case .smallTitle: "小标题"
        case .contentTitle: "内容标题"
        case .body: "正文"
        case .secondary: "副标题与次要文字"
        case .detail: "时间与辅助信息"
        case .action: "按钮与链接"
        }
    }

    func defaultColor(in scheme: ColorScheme) -> Color {
        let color: UIColor
        switch self {
        case .secondary, .detail: color = .secondaryLabel
        case .action: color = .systemBlue
        default: color = .label
        }
        let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
        return Color(uiColor: color.resolvedColor(with: traits))
    }
}

struct StoredTextColor: Codable, Equatable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    init?(color: Color, scheme: ColorScheme) {
        let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
        let value = UIColor(color).resolvedColor(with: traits)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 1
        guard value.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        self.red = Double(red)
        self.green = Double(green)
        self.blue = Double(blue)
        self.alpha = Double(alpha)
    }

    var uiColor: UIColor { UIColor(red: red, green: green, blue: blue, alpha: alpha) }
    var color: Color { Color(uiColor: uiColor) }
}

struct TitleShadowStyle: Codable, Equatable {
    var enabled = false
    var color: StoredTextColor?

    var renderedColor: Color { color?.color ?? .black.opacity(0.45) }
    var uiColor: UIColor { color?.uiColor ?? UIColor.black.withAlphaComponent(0.45) }
}

struct TextPalette: Codable, Equatable {
    var colors: [AppTextRole.RawValue: StoredTextColor] = [:]
    var largeShadow = TitleShadowStyle()
    var smallShadow = TitleShadowStyle()

    func color(for role: AppTextRole) -> Color? { colors[role.rawValue]?.color }
}

struct TextAppearance: Codable {
    var light = TextPalette()
    var dark = TextPalette()

    subscript(scheme: ColorScheme) -> TextPalette {
        get { scheme == .dark ? dark : light }
        set {
            if scheme == .dark { dark = newValue }
            else { light = newValue }
        }
    }

    static func stored() -> Self {
        guard let data = UserDefaults.standard.data(forKey: "appTextAppearance"),
              let appearance = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return appearance
    }
}

private struct AppTextStyle: ViewModifier {
    @EnvironmentObject private var appearance: AppAppearance
    @Environment(\.colorScheme) private var scheme
    let role: AppTextRole

    func body(content: Content) -> some View {
        let palette = appearance.textAppearance[scheme]
        let shadow: TitleShadowStyle? = role == .largeTitle ? palette.largeShadow : role == .smallTitle ? palette.smallShadow : nil
        if let shadow, shadow.enabled {
            content.foregroundStyleIfSet(palette.color(for: role))
                .shadow(color: shadow.renderedColor, radius: role == .largeTitle ? 3 : 2, x: 0, y: 1)
        } else {
            content.foregroundStyleIfSet(palette.color(for: role))
        }
    }
}

private extension View {
    @ViewBuilder func foregroundStyleIfSet(_ color: Color?) -> some View {
        if let color { foregroundStyle(color) }
        else { self }
    }
}

extension View {
    func appTextStyle(_ role: AppTextRole) -> some View { modifier(AppTextStyle(role: role)) }

    func appNavigationTitle(_ title: String) -> some View {
        navigationTitle(title).modifier(AppNavigationTextStyle())
    }
}

struct AppSection<Content: View>: View {
    let title: String
    private let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        Section {
            content
        } header: {
            Text(title).appTextStyle(.smallTitle)
        }
    }
}

private struct AppNavigationTextStyle: ViewModifier {
    @EnvironmentObject private var appearance: AppAppearance
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let palette = appearance.textAppearance[scheme]
        content
            .tint(palette.color(for: .action))
            .background {
                NavigationTitleAttributes(style: .init(palette))
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

private struct NavigationTitleStyle: Equatable {
    let largeColor: StoredTextColor?
    let smallColor: StoredTextColor?
    let largeShadow: TitleShadowStyle
    let smallShadow: TitleShadowStyle

    init(_ palette: TextPalette) {
        largeColor = palette.colors[AppTextRole.largeTitle.rawValue]
        smallColor = palette.colors[AppTextRole.smallTitle.rawValue]
        largeShadow = palette.largeShadow
        smallShadow = palette.smallShadow
    }

    var isCustomized: Bool {
        largeColor != nil || smallColor != nil || largeShadow.enabled || smallShadow.enabled
    }
}

private struct NavigationTitleAttributes: UIViewControllerRepresentable {
    let style: NavigationTitleStyle

    func makeUIViewController(context: Context) -> TitleAttributeController {
        let controller = TitleAttributeController()
        controller.style = style
        return controller
    }

    func updateUIViewController(_ controller: TitleAttributeController, context: Context) {
        controller.style = style
        controller.scheduleUpdate()
    }
}

private final class TitleAttributeController: UIViewController {
    var style: NavigationTitleStyle?
    private weak var appliedItem: UINavigationItem?
    private var original: Appearances?
    private var appliedStyle: NavigationTitleStyle?

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        scheduleUpdate()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        scheduleUpdate()
    }

    func scheduleUpdate() {
        Task { @MainActor [weak self] in self?.apply() }
    }

    private func apply() {
        guard let style, let navigation = navigationController else { return }
        var owner = parent
        while let candidate = owner, !navigation.viewControllers.contains(where: { $0 === candidate }) {
            owner = candidate.parent
        }
        guard let item = owner?.navigationItem else { return }
        if item !== appliedItem {
            if let appliedItem, let original { original.install(on: appliedItem) }
            original = nil
            appliedStyle = nil
            appliedItem = item
        }
        guard appliedStyle != style else { return }
        appliedStyle = style
        guard style.isCustomized else {
            original?.install(on: item)
            original = nil
            return
        }

        let originals = original ?? Appearances(item)
        original = originals
        let bar = navigation.navigationBar
        item.standardAppearance = configured(originals.standard ?? bar.standardAppearance, style: style)
        item.compactAppearance = (originals.compact ?? bar.compactAppearance).map { configured($0, style: style) }
        item.scrollEdgeAppearance = (originals.scrollEdge ?? bar.scrollEdgeAppearance).map { configured($0, style: style) }
        item.compactScrollEdgeAppearance = (originals.compactScrollEdge ?? bar.compactScrollEdgeAppearance).map { configured($0, style: style) }
    }

    private func configured(_ base: UINavigationBarAppearance, style: NavigationTitleStyle) -> UINavigationBarAppearance {
        guard let copy = base.copy() as? UINavigationBarAppearance else { return base }
        copy.titleTextAttributes = attributes(copy.titleTextAttributes, color: style.smallColor, shadow: style.smallShadow, radius: 2)
        copy.largeTitleTextAttributes = attributes(copy.largeTitleTextAttributes, color: style.largeColor, shadow: style.largeShadow, radius: 3)
        return copy
    }

    private func attributes(_ base: [NSAttributedString.Key: Any], color: StoredTextColor?,
                            shadow: TitleShadowStyle, radius: CGFloat) -> [NSAttributedString.Key: Any] {
        var result = base
        if let color { result[.foregroundColor] = color.uiColor }
        if shadow.enabled {
            let effect = NSShadow()
            effect.shadowColor = shadow.uiColor
            effect.shadowOffset = CGSize(width: 0, height: 1)
            effect.shadowBlurRadius = radius
            result[.shadow] = effect
        }
        return result
    }

    private struct Appearances {
        let standard: UINavigationBarAppearance?
        let compact: UINavigationBarAppearance?
        let scrollEdge: UINavigationBarAppearance?
        let compactScrollEdge: UINavigationBarAppearance?

        @MainActor init(_ item: UINavigationItem) {
            standard = item.standardAppearance
            compact = item.compactAppearance
            scrollEdge = item.scrollEdgeAppearance
            compactScrollEdge = item.compactScrollEdgeAppearance
        }

        @MainActor func install(on item: UINavigationItem) {
            item.standardAppearance = standard
            item.compactAppearance = compact
            item.scrollEdgeAppearance = scrollEdge
            item.compactScrollEdgeAppearance = compactScrollEdge
        }
    }
}
