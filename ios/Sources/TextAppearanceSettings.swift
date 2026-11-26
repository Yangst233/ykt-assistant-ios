import SwiftUI

struct TextAppearanceSettings: View {
    @EnvironmentObject private var appearance: AppAppearance
    @State private var scheme: ColorScheme = .light

    private var palette: TextPalette {
        get { appearance.textAppearance[scheme] }
        nonmutating set { appearance.textAppearance[scheme] = newValue }
    }

    var body: some View {
        MaterialForm {
            Picker("配色模式", selection: $scheme) {
                Text("浅色").tag(ColorScheme.light)
                Text("深色").tag(ColorScheme.dark)
            }
            .pickerStyle(.segmented)

            AppSection("文字颜色") {
                ForEach(AppTextRole.allCases) { role in
                    HStack(spacing: 12) {
                        ColorPicker(role.title, selection: color(role), supportsOpacity: false)
                        if palette.colors[role.rawValue] != nil {
                            Button {
                                palette.colors.removeValue(forKey: role.rawValue)
                            } label: {
                                Image(systemName: "arrow.counterclockwise")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("恢复\(role.title)默认颜色")
                        }
                    }
                }
            }

            shadowSection("大标题阴影", keyPath: \.largeShadow)
            shadowSection("小标题阴影", keyPath: \.smallShadow)

            AppSection("当前模式预览") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("导航大标题").font(.largeTitle.bold()).appTextStyle(.largeTitle)
                    Text("小标题").font(.headline).appTextStyle(.smallTitle)
                    Text("内容标题").font(.subheadline.weight(.semibold)).appTextStyle(.contentTitle)
                    Text("正文").appTextStyle(.body)
                    Text("副标题与次要文字").appTextStyle(.secondary, fallback: .secondary)
                    Text("时间与辅助信息").font(.footnote).appTextStyle(.detail, fallback: .secondary)
                    Text("按钮与链接").foregroundStyle(palette.color(for: .action) ?? .accentColor)
                }
                .environment(\.colorScheme, scheme)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(scheme == .dark ? Color.black : Color.white, in: RoundedRectangle(cornerRadius: 12))
            }
            Button("恢复当前模式默认值", role: .destructive) { palette = TextPalette() }
        }
        .wallpaperSurface()
        .appNavigationTitle("文字与标题")
    }

    private func color(_ role: AppTextRole) -> Binding<Color> {
        Binding {
            palette.color(for: role) ?? role.defaultColor(in: scheme)
        } set: { value in
            if let stored = StoredTextColor(color: value, scheme: scheme) {
                palette.colors[role.rawValue] = stored
            }
        }
    }

    private func shadowSection(_ title: String, keyPath: WritableKeyPath<TextPalette, TitleShadowStyle>) -> some View {
        AppSection(title) {
            Toggle("启用阴影", isOn: Binding {
                palette[keyPath: keyPath].enabled
            } set: { value in
                palette[keyPath: keyPath].enabled = value
            })
            ColorPicker("阴影颜色", selection: Binding {
                palette[keyPath: keyPath].renderedColor
            } set: { value in
                if let stored = StoredTextColor(color: value, scheme: scheme) {
                    palette[keyPath: keyPath].color = stored
                }
            })
            .disabled(!palette[keyPath: keyPath].enabled)
        }
    }
}
