import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - set_text 的参数 → 一段文字
//
// 管什么：AI 给的颜色、位置、字号、动画这些参数怎么落到 `TextOverlay` 上；颜色的读写。
// 纯值，自检够得着（scripts/check-mcp.sh）。夹紧照旧只走 `TimelineState.updateTextOverlay`
// 那一处（`clampToValidRange`），这里不另夹一份。
// 不管什么：新建放哪一行、选中谁、预览跳到哪（AITimelineTools）。

enum AIColor {
    /// "#RRGGBB" / "#RRGGBBAA" / 几个常用颜色名。"none" / "transparent" 返回 nil（= 去掉）。
    static func parse(_ text: String) throws -> SubtitleColor? {
        let value = text.trimmingCharacters(in: .whitespaces).lowercased()
        if ["none", "transparent", "clear", ""].contains(value) { return nil }
        if let named = named[value] { return named }
        let hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
        guard hex.count == 6 || hex.count == 8, let number = UInt64(hex, radix: 16) else {
            throw AIToolError("Colour \"\(text)\" is not #RRGGBB, #RRGGBBAA or a colour name.")
        }
        let hasAlpha = hex.count == 8
        let rgb = hasAlpha ? number >> 8 : number
        return SubtitleColor(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255,
            opacity: hasAlpha ? Double(number & 0xFF) / 255 : 1
        )
    }

    static func hex(_ color: SubtitleColor) -> String {
        func byte(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        var text = String(format: "#%02X%02X%02X", byte(color.red), byte(color.green), byte(color.blue))
        if color.opacity < 0.999 { text += String(format: "%02X", byte(color.opacity)) }
        return text
    }

    private static let named: [String: SubtitleColor] = [
        "white": .white, "black": .black, "yellow": .yellow,
        "red": SubtitleColor(red: 0.95, green: 0.2, blue: 0.2),
        "orange": SubtitleColor(red: 1, green: 0.55, blue: 0.1),
        "green": SubtitleColor(red: 0.2, green: 0.8, blue: 0.35),
        "blue": SubtitleColor(red: 0.2, green: 0.45, blue: 1),
        "cyan": SubtitleColor(red: 0.1, green: 0.85, blue: 0.95),
        "purple": SubtitleColor(red: 0.6, green: 0.3, blue: 0.95),
        "pink": SubtitleColor(red: 1, green: 0.45, blue: 0.7),
        "gray": SubtitleColor(red: 0.5, green: 0.5, blue: 0.5),
        "grey": SubtitleColor(red: 0.5, green: 0.5, blue: 0.5)
    ]
}

/// 几个有名字的位置：文字块中心落在画面高度的哪儿。
enum AITextPlacement {
    static func centerY(for position: String) -> Double {
        switch position {
        case "top": return 0.12
        case "upper_third": return 0.33
        case "lower_third": return 0.72
        case "bottom": return 0.88
        default: return 0.5
        }
    }
}

/// set_text 里「只改传了的」那些字段。
struct AITextChange {
    var text: String?
    var start: Double?
    var duration: Double?
    var centerX: Double?
    var centerY: Double?
    var boxWidth: Double?
    var font: String?
    var fontSize: Double?
    var bold: Bool?
    var italic: Bool?
    /// 外层 nil = 没提；内层 nil = 去掉。
    var color: SubtitleColor?
    var alignment: TextBlockAlignment?
    var strokeColor: SubtitleColor??
    var strokeWidth: Double?
    var shadow: Bool?
    var background: SubtitleColor??
    var animationIn: TextAnimationKind?
    var animationOut: TextAnimationKind?
    var animationInDuration: Double?
    var animationOutDuration: Double?
    var animationIntensity: Double?
    var emphasis: TextEmphasisKind?
    var letterSpacing: Double?
    /// 顺时针转几度（界面上旋转把手转的那个，2026-10-03 给 AI 开的）。
    var rotation: Double?
    /// 数字滚动（AITextNumberChange）；没给是 nil。
    var number: AINumberRollChange?
    var hidden: Bool?

    init(_ args: AIToolArguments) throws {
        text = try args.string("text").map(Self.unescapingNewlines)
        start = try args.double("start")
        duration = try args.double("duration")
        if let position = try args.choice("position", from: MCPVocabulary.textPositions) {
            centerX = 0.5
            centerY = AITextPlacement.centerY(for: position)
        }
        if let x = try args.double("x") { centerX = x }
        if let y = try args.double("y") { centerY = y }
        boxWidth = try args.double("box_width")
        font = try args.string("font")
        fontSize = try args.double("font_size")
        bold = try args.bool("bold")
        italic = try args.bool("italic")
        if let text = try args.string("color") {
            guard let parsed = try AIColor.parse(text) else { throw AIToolError("color cannot be none.") }
            color = parsed
        }
        switch try args.choice("alignment", from: MCPVocabulary.textAlignments) {
        case "left": alignment = .leading
        case "right": alignment = .trailing
        case "center": alignment = .center
        default: break
        }
        if let text = try args.string("stroke_color") { strokeColor = .some(try AIColor.parse(text)) }
        strokeWidth = try args.double("stroke_width")
        shadow = try args.bool("shadow")
        if let text = try args.string("background_color") { background = .some(try AIColor.parse(text)) }
        animationIn = try Self.animation(args, "animation_in")
        animationOut = try Self.animation(args, "animation_out")
        animationInDuration = try args.double("animation_in_duration")
        animationOutDuration = try args.double("animation_out_duration")
        animationIntensity = try args.double("animation_intensity")
        emphasis = try args.choice("emphasis", from: MCPVocabulary.textEmphasis).flatMap(TextEmphasisKind.init(rawValue:))
        letterSpacing = try args.double("letter_spacing")
        rotation = try args.double("rotation")
        number = try AINumberRollChange(args)
        hidden = try args.bool("hidden")
    }

    private static func animation(_ args: AIToolArguments, _ key: String) throws -> TextAnimationKind? {
        try args.choice(key, from: MCPVocabulary.textAnimations).flatMap(TextAnimationKind.init(rawValue:))
    }

    /// 字面的反斜杠 + n 也当换行：工具说明里写着 `\n`，客户端常常把它原样当两个字符传过来，画面上就真的
    /// 显示一个反斜杠和一个 n（2026-09-29 婚礼工程）。屏幕上的字不会真要一个反斜杠加 n。
    static func unescapingNewlines(_ text: String) -> String {
        text.replacingOccurrences(of: "\\n", with: "\n")
    }

    /// 落到一段文字上。夹紧由调用方经 `updateTextOverlay` 统一收（新建的也走那一处）。
    func apply(to overlay: inout TextOverlay) {
        if let text { overlay.text = text }
        if let start { overlay.timelineStart = start }
        if let duration { overlay.duration = duration }
        if let centerX { overlay.centerX = centerX }
        if let centerY { overlay.centerY = centerY }
        if let boxWidth { overlay.boxWidth = boxWidth }
        if let font { overlay.style.fontName = font }
        if let fontSize { overlay.style.fontSize = fontSize }
        if let bold { overlay.style.bold = bold }
        if let italic { overlay.style.italic = italic }
        if let color { overlay.style.fill = .solid(color) }
        if let alignment { overlay.style.alignment = alignment }
        if let strokeColor {
            overlay.style.stroke = strokeColor.map {
                TextStroke(color: $0, width: strokeWidth ?? overlay.style.stroke?.width ?? TextStroke.default.width)
            }
        } else if let strokeWidth {
            overlay.style.stroke = TextStroke(color: overlay.style.stroke?.color ?? .black, width: strokeWidth)
        }
        if let shadow { overlay.style.shadow = shadow ? (TextStyle.default.shadow ?? TextShadow.default) : nil }
        if let background {
            overlay.style.background = background.map { color in
                var box = overlay.style.background ?? TextBackground.default
                box.color = color
                return box
            }
        }
        if let animationIn { overlay.animation.entrance = animationIn }
        if let animationOut { overlay.animation.exit = animationOut }
        if let animationInDuration { overlay.animation.entranceDuration = animationInDuration }
        if let animationOutDuration { overlay.animation.exitDuration = animationOutDuration }
        if let animationIntensity { overlay.animation.intensity = animationIntensity }
        if let emphasis { overlay.animation.emphasis = emphasis }
        if let letterSpacing { overlay.style.letterSpacing = letterSpacing }
        if let rotation { overlay.rotationDegrees = rotation }
        number?.apply(to: &overlay)
        if let hidden { overlay.isHidden = hidden }
    }
}

/// 字放不放得下：AI 看不见画面，字号给大了它自己不知道（2026-09-27 端到端实测：竖屏里 110 号的
/// 「Antarctica」被从词中间折成「Antarctic / a」；同一天冒烟：130 号的「南极探险」折成两行、顶出了画面上沿）。
/// 结果里回行数和文字块的位置，词被折断了、块出了画面，各给一句提示让它改。
enum AITextFit {
    /// 文字块（版面框）出了画面多少像素。
    struct Overflow: Equatable {
        var top = 0.0
        var bottom = 0.0
        var left = 0.0
        var right = 0.0
    }

    /// 版面框（`TextRenderer.layoutFrame`，预览选中框也是它）出了画面：各边出去多少像素；
    /// 差不到半个像素的不算，全在画面里是 nil。
    static func overflow(of frame: CGRect, canvas: CGSize) -> Overflow? {
        let out = Overflow(
            top: max(0, -frame.minY), bottom: max(0, frame.maxY - canvas.height),
            left: max(0, -frame.minX), right: max(0, frame.maxX - canvas.width)
        )
        return max(out.top, out.bottom, out.left, out.right) > 0.5 ? out : nil
    }

    /// 「top by 12 px, right by 3 px」。
    static func describe(_ overflow: Overflow) -> String {
        [("top", overflow.top), ("bottom", overflow.bottom), ("left", overflow.left), ("right", overflow.right)]
            .filter { $0.1 > 0.5 }
            .map { "\($0.0) by \(Int($0.1.rounded(.up))) px" }
            .joined(separator: ", ")
    }

    /// 被从中间折断的那个词（折行正好落在两个相邻的字母之间）；没有就是 nil。
    /// 中文、日文、韩文本来就逐字折行，不算。
    static func brokenWord(in layout: TextLayout, text: String) -> String? {
        let units = Array(text.utf16)
        for (line, next) in zip(layout.lines, layout.lines.dropFirst()) {
            guard let last = line.glyphs.map(\.characterIndex).max(),
                  let first = next.glyphs.map(\.characterIndex).min(),
                  first == last + 1, isWordUnit(units, last), isWordUnit(units, first) else { continue }
            var lower = last
            while lower > 0, isWordUnit(units, lower - 1) { lower -= 1 }
            var upper = first
            while upper + 1 < units.count, isWordUnit(units, upper + 1) { upper += 1 }
            return String(utf16CodeUnits: Array(units[lower...upper]), count: upper - lower + 1)
        }
        return nil
    }

    /// 拼音文字的字母或数字（CJK 从 U+2E80 起，那一带逐字折行是正常的）。
    private static func isWordUnit(_ units: [UInt16], _ index: Int) -> Bool {
        guard units.indices.contains(index), units[index] < 0x2E80,
              let scalar = Unicode.Scalar(UInt32(units[index])) else { return false }
        return scalar.properties.isAlphabetic || ("0"..."9").contains(Character(scalar))
    }
}
