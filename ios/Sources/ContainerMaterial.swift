import SwiftUI

enum ContainerMaterial: String, CaseIterable, Identifiable {
    case standard, regularGlass, clearGlass, frosted

    var id: Self { self }

    var title: String {
        switch self {
        case .standard: "默认"
        case .regularGlass: "标准玻璃"
        case .clearGlass: "透明玻璃"
        case .frosted: "磨砂玻璃"
        }
    }
}

private struct ContainerSurface<SurfaceShape: Shape>: ViewModifier {
    @EnvironmentObject private var appearance: AppAppearance
    @Environment(\.colorScheme) private var colorScheme
    let material: ContainerMaterial
    let shape: SurfaceShape

    func body(content: Content) -> some View {
        content.background {
            ZStack {
                baseSurface
                if material != .standard && appearance.glassDensity > 0 {
                    shape.fill(shade.opacity(appearance.glassDensity * maximumShade))
                }
            }
            .accessibilityHidden(true)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder private var baseSurface: some View {
        switch material {
        case .standard:
            shape.fill(Color(uiColor: .secondarySystemGroupedBackground))
        case .frosted:
            shape.fill(.ultraThinMaterial)
        case .regularGlass, .clearGlass:
            if #available(iOS 26.0, *) {
                shape.fill(.clear)
                    .glassEffect(material == .regularGlass ? .regular : .clear, in: shape)
            } else {
                shape.fill(material == .regularGlass ? Material.thin : Material.ultraThin)
            }
        }
    }

    private var shade: Color { colorScheme == .dark ? .black : .white }

    // Draw the shade above the glass sample and below the content. The glass still samples the wallpaper.
    private var maximumShade: Double {
        switch material {
        case .standard: 0
        case .regularGlass: 0.72
        case .clearGlass: 0.82
        case .frosted: 0.76
        }
    }
}

extension View {
    fileprivate func containerSurface<S: Shape>(_ material: ContainerMaterial, in shape: S) -> some View {
        modifier(ContainerSurface(material: material, shape: shape))
    }

    @ViewBuilder func standaloneContainerRow() -> some View {
        if #available(iOS 18.0, *) {
            self.containerValue(\.isStandaloneContainer, true)
        } else {
            self
        }
    }

    func standaloneContainer(cornerRadius: CGFloat) -> some View {
        modifier(StandaloneContainer(cornerRadius: cornerRadius))
    }
}

@available(iOS 18.0, *)
extension ContainerValues {
    @Entry fileprivate var isStandaloneContainer = false
    @Entry var ownsGlassRowLayout = false
}

private struct StandaloneContainer: ViewModifier {
    @EnvironmentObject private var appearance: AppAppearance
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let style = reduceTransparency || contrast == .increased ? .standard : appearance.containerMaterial
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        return content.containerSurface(style, in: shape).clipShape(shape)
    }
}

struct MaterialList<Rows: View>: View {
    private let rows: Rows

    init(@ViewBuilder content: () -> Rows) { rows = content() }

    var body: some View {
        MaterialCollection(rows: rows, form: false).appTextStyle(.body)
    }
}

struct MaterialForm<Rows: View>: View {
    private let rows: Rows

    init(@ViewBuilder content: () -> Rows) { rows = content() }

    var body: some View {
        MaterialCollection(rows: rows, form: true).appTextStyle(.body)
    }
}

private struct MaterialCollection<Rows: View>: View {
    @EnvironmentObject private var appearance: AppAppearance
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    let rows: Rows
    let form: Bool

    var body: some View {
        if #available(iOS 18.0, *), appearance.containerMaterial != .standard,
           !reduceTransparency, contrast != .increased {
            MaterialScroll(rows: rows, material: appearance.containerMaterial)
        } else if form {
            Form { rows }
        } else {
            List { rows }
        }
    }
}

@available(iOS 18.0, *)
private struct MaterialScroll<Rows: View>: View {
    @Environment(\.refresh) private var refresh
    let rows: Rows
    let material: ContainerMaterial

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                ForEach(sections: rows) { section in
                    if !section.content.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            if !section.header.isEmpty {
                                VStack(alignment: .leading, spacing: 4) { section.header }
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 16)
                            }
                            GlassSection(rows: section.content, material: material)
                            if !section.footer.isEmpty {
                                VStack(alignment: .leading, spacing: 4) { section.footer }
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .appTextStyle(.detail)
                                    .padding(.horizontal, 16)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, GlassRowMetrics.horizontal + 4)
            .padding(.vertical, 12)
        }
        .environment(\.usesGlassRows, true)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            if let refresh {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("刷新", systemImage: "arrow.clockwise") {
                        Task { await refresh() }
                    }
                }
            }
        }
    }
}

@available(iOS 18.0, *)
private struct GlassSection: View {
    let rows: SubviewsCollection
    let material: ContainerMaterial

    var body: some View {
        if rows.count == 1, let row = rows.first, row.containerValues.isStandaloneContainer {
            row
        } else {
            let lastID = rows.last?.id
            let radius: CGFloat = if #available(iOS 26.0, *) { 24 } else { 12 }
            let shape = RoundedRectangle(cornerRadius: radius)
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 0) {
                        if row.containerValues.ownsGlassRowLayout {
                            row
                        } else {
                            row.glassRowContent()
                        }
                        if row.id != lastID {
                            Divider()
                                .opacity(0.65)
                                .padding(.leading, GlassRowMetrics.horizontal)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
            .containerSurface(material, in: shape)
            .clipShape(shape)
        }
    }
}
