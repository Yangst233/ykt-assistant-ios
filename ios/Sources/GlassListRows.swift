import SwiftUI

private struct GlassRowsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var usesGlassRows: Bool {
        get { self[GlassRowsKey.self] }
        set { self[GlassRowsKey.self] = newValue }
    }
}

enum GlassRowMetrics {
    static let horizontal: CGFloat = 16
    static let vertical: CGFloat = 12
    static let minimumHeight: CGFloat = 44
}

extension View {
    func glassRowContent() -> some View {
        self
            .padding(.horizontal, GlassRowMetrics.horizontal)
            .padding(.vertical, GlassRowMetrics.vertical)
            .frame(maxWidth: .infinity, minHeight: GlassRowMetrics.minimumHeight, alignment: .leading)
    }

    @ViewBuilder func ownsGlassRowLayout() -> some View {
        if #available(iOS 18.0, *) {
            self.containerValue(\.ownsGlassRowLayout, true)
        } else {
            self
        }
    }

    func glassNavigationInteraction() -> some View {
        modifier(GlassNavigationInteraction()).ownsGlassRowLayout()
    }
}

private struct GlassNavigationInteraction: ViewModifier {
    @Environment(\.usesGlassRows) private var glass

    func body(content: Content) -> some View {
        if glass {
            content.buttonStyle(GlassRowPressStyle())
        } else {
            content
        }
    }
}

private struct GlassRowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                if configuration.isPressed { Rectangle().fill(.quaternary) }
            }
    }
}

struct NavigationRowLabel<Content: View>: View {
    @Environment(\.usesGlassRows) private var glass
    let showsArrowInNativeList: Bool
    private let content: Content

    init(showsArrowInNativeList: Bool = false, @ViewBuilder content: () -> Content) {
        self.showsArrowInNativeList = showsArrowInNativeList
        self.content = content()
    }

    var body: some View {
        if glass {
            row.glassRowContent().contentShape(Rectangle())
        } else {
            row.contentShape(Rectangle())
        }
    }

    private var row: some View {
        HStack(alignment: .center, spacing: 12) {
            content.font(.body).appTextStyle(.contentTitle, fallback: .primary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if glass || showsArrowInNativeList {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
    }
}

struct SettingsPickerRow<Selection: Hashable, Options: View>: View {
    @Environment(\.usesGlassRows) private var glass
    let title: String
    let value: String
    @Binding var selection: Selection
    private let options: Options

    init(_ title: String, value: String, selection: Binding<Selection>, @ViewBuilder options: () -> Options) {
        self.title = title
        self.value = value
        _selection = selection
        self.options = options()
    }

    var body: some View {
        Group {
            if glass {
                Menu {
                    Picker(title, selection: $selection) { options }
                } label: {
                    HStack(spacing: 8) {
                        Text(title).appTextStyle(.body, fallback: .primary).layoutPriority(1)
                        Spacer(minLength: 12)
                        Text(value).appTextStyle(.secondary).lineLimit(1).truncationMode(.tail)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.footnote.weight(.medium))
                            .accessibilityHidden(true)
                    }
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .glassRowContent()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title)
                .accessibilityValue(value)
            } else {
                Picker(title, selection: $selection) { options }
            }
        }
    }
}
