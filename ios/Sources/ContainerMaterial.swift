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
    let material: ContainerMaterial
    let shape: SurfaceShape

    func body(content: Content) -> some View {
        content.background {
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
        List { MaterialSections(rows: rows) }
    }
}

struct MaterialForm<Rows: View>: View {
    private let rows: Rows

    init(@ViewBuilder content: () -> Rows) { rows = content() }

    var body: some View {
        Form { MaterialSections(rows: rows) }
    }
}

private struct MaterialSections<Rows: View>: View {
    @EnvironmentObject private var appearance: AppAppearance
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    let rows: Rows

    var body: some View {
        if #available(iOS 18.0, *), appearance.containerMaterial != .standard,
           !reduceTransparency, contrast != .increased {
            ForEach(sections: rows) { section in
                Section {
                    let elements = section.content
                    ForEach(elements) { row in
                        if row.containerValues.isStandaloneContainer {
                            row.listRowBackground(Color.clear)
                        } else {
                            let top = row.id == elements.first?.id
                            let bottom = row.id == elements.last?.id
                            row.listRowBackground(RowSurface(material: appearance.containerMaterial, top: top, bottom: bottom))
                        }
                    }
                } header: {
                    section.header
                } footer: {
                    section.footer
                }
            }
        } else {
            rows
        }
    }
}

private struct RowSurface: View {
    let material: ContainerMaterial
    let top: Bool
    let bottom: Bool

    var body: some View {
        let radius: CGFloat = if #available(iOS 26.0, *) { 24 } else { 12 }
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: top ? radius : 0,
            bottomLeadingRadius: bottom ? radius : 0,
            bottomTrailingRadius: bottom ? radius : 0,
            topTrailingRadius: top ? radius : 0
        )
        Color.clear.containerSurface(material, in: shape)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}
