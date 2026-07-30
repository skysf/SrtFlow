import SwiftUI
import SrtFlowCore

/// 自定义预设的存放处。内置预设不可改不可删，用户存的写进 UserDefaults。
@MainActor
final class StylePresetStore: ObservableObject {
    @Published private(set) var customPresets: [BurnInStyle] = []

    static let shared = StylePresetStore()

    private let storageKey = "burnInCustomPresets"

    private init() {
        load()
    }

    var allPresets: [BurnInStyle] { BurnInStyle.builtInPresets + customPresets }

    /// 存一份新的自定义预设。同名的会被覆盖。
    func save(_ style: BurnInStyle, name: String) {
        var copy = style
        copy.name = name
        copy.isBuiltIn = false
        if let index = customPresets.firstIndex(where: { $0.name == name }) {
            copy.id = customPresets[index].id
            customPresets[index] = copy
        } else {
            copy.id = UUID()
            customPresets.append(copy)
        }
        persist()
    }

    func delete(id: UUID) {
        customPresets.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(customPresets) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([BurnInStyle].self, from: data) else { return }
        customPresets = decoded
    }
}

/// 字体、颜色、位置的调节面板。
struct SubtitleStyleEditor: View {
    @Binding var style: BurnInStyle
    @ObservedObject var fontCatalog: FontCatalogStore
    @ObservedObject var presets: StylePresetStore
    /// 拖边距滑块时让预览上闪出参考线。
    @ObservedObject var guides: MarginGuideFlash

    @State private var newPresetName = ""
    @State private var isNamingPreset = false

    var body: some View {
        Form {
            Section("Preset") {
                presetPicker
                presetButtons
            }

            Section("Font") {
                fontPicker

                LabeledSlider(
                    label: "Size",
                    value: $style.fontSize,
                    range: BurnInStyle.fontSizeRange,
                    step: 1,
                    readout: "\(Int(style.fontSize))"
                )
                Text("Sizes are relative to a 1080p frame, so the same style looks identical on 720p and 4K exports.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 16) {
                    Toggle("Bold", isOn: $style.bold)
                    Toggle("Italic", isOn: $style.italic)
                    Spacer()
                }

                LabeledSlider(
                    label: "Letter spacing",
                    value: $style.letterSpacing,
                    range: -4...16,
                    step: 0.5,
                    readout: String(format: "%.1f", style.letterSpacing)
                )
            }

            Section("Colours") {
                ColorPicker("Text", selection: colorBinding(\.fillColor), supportsOpacity: true)

                Picker("Background", selection: $style.borderStyle) {
                    Text("Outline").tag(SubtitleBorderStyle.outline)
                    Text("Solid bar").tag(SubtitleBorderStyle.box)
                }
                .pickerStyle(.segmented)

                // BorderStyle 3 下，libass 是用 OutlineColour 画底框、Outline 当内边距的，
                // 所以这两个控件在两种模式下要换名字，不然完全对不上用户的直觉。
                switch style.borderStyle {
                case .outline:
                    ColorPicker("Outline", selection: colorBinding(\.outlineColor), supportsOpacity: true)
                    LabeledSlider(
                        label: "Outline width",
                        value: $style.outlineWidth,
                        range: BurnInStyle.outlineWidthRange,
                        step: 0.5,
                        readout: String(format: "%.1f", style.outlineWidth)
                    )
                    ColorPicker("Shadow", selection: colorBinding(\.shadowColor), supportsOpacity: true)
                    LabeledSlider(
                        label: "Shadow offset",
                        value: $style.shadowOffset,
                        range: BurnInStyle.shadowOffsetRange,
                        step: 0.5,
                        readout: String(format: "%.1f", style.shadowOffset)
                    )
                case .box:
                    ColorPicker("Bar colour", selection: colorBinding(\.outlineColor), supportsOpacity: true)
                    LabeledSlider(
                        label: "Bar padding",
                        value: $style.outlineWidth,
                        range: 0...20,
                        step: 0.5,
                        readout: String(format: "%.1f", style.outlineWidth)
                    )
                    Text("A solid bar behind the text stays readable over busy footage.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Position") {
                PositionGrid(position: $style.position)

                // 这两个滑块拖的时候会在预览上画出参考线（`MarginGuideFlash`）：
                // 光看数字想象不出边距在哪儿，尤其它还决定长句在哪换行。
                LabeledSlider(
                    label: style.position.isVerticallyCentered ? "Vertical offset" : "Distance from edge",
                    value: Binding(
                        get: { Double(style.marginVertical) },
                        set: {
                            style.marginVertical = Int($0.rounded())
                            guides.flash()
                        }
                    ),
                    range: Double(BurnInStyle.marginRange.lowerBound)...Double(BurnInStyle.marginRange.upperBound),
                    step: 5,
                    readout: "\(style.marginVertical)",
                    onEditingChanged: { guides.setDragging($0) }
                )
                LabeledSlider(
                    label: "Side margins",
                    value: Binding(
                        get: { Double(style.marginHorizontal) },
                        set: {
                            style.marginHorizontal = Int($0.rounded())
                            guides.flash()
                        }
                    ),
                    range: Double(BurnInStyle.marginRange.lowerBound)...Double(BurnInStyle.marginRange.upperBound),
                    step: 5,
                    readout: "\(style.marginHorizontal)",
                    onEditingChanged: { guides.setDragging($0) }
                )
                Text("Side margins also decide where long lines wrap. Guide lines appear on the preview while you drag.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 预设

    private var presetPicker: some View {
        Menu {
            ForEach(BurnInStyle.builtInPresets) { preset in
                Button(LocalizedStringKey(preset.name)) { apply(preset) }
            }
            if !presets.customPresets.isEmpty {
                Divider()
                ForEach(presets.customPresets) { preset in
                    Button(preset.name) { apply(preset) }
                }
            }
        } label: {
            HStack {
                Text(currentPresetLabel)
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
        }
    }

    /// 当前设置跟哪个预设一模一样就显示它的名字，改动过就标出来。
    private var currentPresetLabel: String {
        if let match = presets.allPresets.first(where: { matches($0, style) }) {
            // 内置预设的名字是字符串表里的 key，用户自建的名字原样显示。
            return match.isBuiltIn ? L10n(match.name) : match.name
        }
        return L10n("Custom")
    }

    private var presetButtons: some View {
        HStack {
            if isNamingPreset {
                TextField("Preset name", text: $newPresetName)
                    .onSubmit(commitPreset)
                Button("Save") { commitPreset() }
                    .disabled(newPresetName.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel") {
                    isNamingPreset = false
                    newPresetName = ""
                }
            } else {
                Button {
                    newPresetName = ""
                    isNamingPreset = true
                } label: {
                    Label("Save as preset", systemImage: "plus")
                }
                if let custom = presets.customPresets.first(where: { matches($0, style) }) {
                    Button(role: .destructive) {
                        presets.delete(id: custom.id)
                    } label: {
                        Label("Delete preset", systemImage: "trash")
                    }
                }
                Spacer()
            }
        }
        .controlSize(.small)
    }

    private func commitPreset() {
        let name = newPresetName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        presets.save(style, name: name)
        isNamingPreset = false
        newPresetName = ""
    }

    /// 换预设时保留当前选好的字体 —— 内置预设里的字体名只是占位，
    /// 用户挑好的中文字体不该被一次换预设弄丢。
    private func apply(_ preset: BurnInStyle) {
        var next = preset
        // 内置预设里的字体名只是个占位值。用户挑好的中文字体不该因为换了个
        // 配色预设就被弄丢；自己存的预设则连字体一起用。
        if preset.isBuiltIn {
            next.fontName = style.fontName
        }
        style = next
    }

    /// 比较时忽略 id、名字和字体，只看视觉参数。
    private func matches(_ lhs: BurnInStyle, _ rhs: BurnInStyle) -> Bool {
        var a = lhs, b = rhs
        a.id = UUID(); b.id = a.id
        a.name = ""; b.name = ""
        a.isBuiltIn = false; b.isBuiltIn = false
        a.fontName = ""; b.fontName = ""
        return a == b
    }

    // MARK: - 字体

    private var fontPicker: some View {
        FontPickerField(fontName: $style.fontName, catalog: fontCatalog)
    }

    private func colorBinding(_ keyPath: WritableKeyPath<BurnInStyle, SubtitleColor>) -> Binding<Color> {
        Binding(
            get: { style[keyPath: keyPath].swiftUIColor },
            set: { style[keyPath: keyPath] = SubtitleColor($0) }
        )
    }
}

/// 带数值读出的滑杆。
private struct LabeledSlider: View {
    let label: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let readout: String
    /// 开始/结束拖动。按住不动时也算在拖，边距参考线靠它决定什么时候开始倒计时。
    var onEditingChanged: ((Bool) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                Spacer()
                Text(readout).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step) { editing in
                onEditingChanged?(editing)
            }
        }
    }
}

/// 九宫格位置选择，对应 ASS 的小键盘式 Alignment。
private struct PositionGrid: View {
    @Binding var position: SubtitlePosition

    /// 界面上从上往下排，所以行序要跟 ASS 的编号反过来。
    private let rows: [[SubtitlePosition]] = [
        [.topLeft, .topCenter, .topRight],
        [.middleLeft, .middleCenter, .middleRight],
        [.bottomLeft, .bottomCenter, .bottomRight]
    ]

    var body: some View {
        VStack(spacing: 4) {
            ForEach(rows.indices, id: \.self) { rowIndex in
                HStack(spacing: 4) {
                    ForEach(rows[rowIndex], id: \.self) { candidate in
                        Button {
                            position = candidate
                        } label: {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(position == candidate ? Color.accentColor : Color.primary.opacity(0.08))
                                .frame(height: 22)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .strokeBorder(.separator, lineWidth: 0.5)
                                )
                        }
                        .buttonStyle(.plain)
                        .help(helpText(for: candidate))
                    }
                }
            }
        }
        .frame(maxWidth: 180)
        .padding(.vertical, 2)
    }

    private func helpText(for position: SubtitlePosition) -> LocalizedStringKey {
        switch position {
        case .topLeft: return "Top left"
        case .topCenter: return "Top centre"
        case .topRight: return "Top right"
        case .middleLeft: return "Middle left"
        case .middleCenter: return "Centre"
        case .middleRight: return "Middle right"
        case .bottomLeft: return "Bottom left"
        case .bottomCenter: return "Bottom centre"
        case .bottomRight: return "Bottom right"
        }
    }
}
