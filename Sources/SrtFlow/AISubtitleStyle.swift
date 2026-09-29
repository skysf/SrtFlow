import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - 字幕长什么样：edit_subtitles / burn_subtitles 的 style（纯值）
//
// 管什么：AI 给的 style 读成类型、先全验过（位置、离边多远、字号、字体、粗细、颜色、描边或底条、阴影、逐词高亮），再落下去：
// - edit_subtitles：落到**这个工程自己的**样式上（方案第 54 条：不动用户在烧录页记住的那套），从此刻用的那套
//   （`subtitleStyle(appWide:)`）改起。给了位置 / 离边距离就收掉拖框的布局（它锚定在底部中心，会盖住这里给的位置），
//   只给字号就把布局的字号倍率归一（倍率会乘在字号上）。逐词高亮落到工程的 `subtitleHighlight`。
// - burn_subtitles：落到这一批自带的那份上（烧录页记住的那套不动；字幕文件里没有词的时间，逐词高亮不适用）。
// 以及回给 AI 看的「现在长什么样」（`describe`）。
// 不管什么：字体表从哪来（FontCatalogStore，调用方给）、提交和撤销（AISubtitleTools / AIEncodeTools）。

struct AISubtitleStyleChange: Equatable {
    var reset = false
    var position: SubtitlePosition?
    /// 离那条边多远（1080 基准像素）。
    var margin: Int?
    var size: Double?
    var font: String?
    var bold: Bool?
    var color: SubtitleColor?
    /// 描边的颜色；`.some(nil)` = 不要描边。
    var outline: SubtitleColor??
    /// 描边多粗（底条时是底条的内边距），1080 基准像素。
    var outlineWidth: Double?
    /// 底条的颜色；`.some(nil)` = 不要底条（回到描边）。
    var box: SubtitleColor??
    /// 阴影的颜色（只跟描边一起画，底条模式没有阴影）；`.some(nil)` = 不要阴影。
    var shadow: SubtitleColor??
    /// 逐词高亮的颜色；`.some(nil)` = 关掉。
    var highlight: SubtitleColor??
    var highlightScale: Double?

    /// 词表（小程序的 MCPVocabulary.subtitlePositions）→ 九宫格里居中的那一列。
    static let positions: [(name: String, value: SubtitlePosition)] = [
        ("bottom", .bottomCenter), ("middle", .middleCenter), ("top", .topCenter)
    ]

    /// 离边最多是画面高的多少。
    static let marginRange = 0.0...0.45

    /// `shadow: true` 的颜色：烧录页「白字阴影」那套。
    static let defaultShadow = SubtitleColor(red: 0, green: 0, blue: 0, opacity: 0.75)

    /// `style` 没给是 nil；给了但不是对象、或者哪一项不对就报错（一样都不改）。字体名这里不认，见 `resolvingFont`。
    init?(_ args: AIToolArguments) throws {
        guard let raw = args.raw["style"], !raw.isNull else { return nil }
        guard case .object = raw else { throw AIToolError("style must be an object, e.g. {\"position\": \"top\", \"size\": 64}.") }
        let fields = AIToolArguments(raw)
        reset = try fields.bool("reset") ?? false
        if let name = try fields.choice("position", from: MCPVocabulary.subtitlePositions) {
            position = Self.positions.first { $0.name == name }?.value
        }
        if let fraction = try fields.double("margin") {
            guard Self.marginRange.contains(fraction) else {
                throw AIToolError("style.margin is a fraction of the frame height, from 0 to \(Self.marginRange.upperBound).")
            }
            margin = Int((fraction * Double(BurnInStyle.referenceHeight)).rounded())
        }
        if let value = try fields.double("size") {
            guard BurnInStyle.fontSizeRange.contains(value) else {
                throw AIToolError("style.size must be 20 to 140 (pixels on a frame 1080 pixels tall).")
            }
            size = value
        }
        font = try fields.string("font")?.trimmingCharacters(in: .whitespaces)
        bold = try fields.bool("bold")
        if let text = try fields.string("color") {
            guard let parsed = try AIColor.parse(text) else { throw AIToolError("style.color needs a colour.") }
            color = parsed
        }
        if let text = try fields.string("outline") { outline = .some(try AIColor.parse(text)) }
        if let width = try fields.double("outline_width") {
            guard BurnInStyle.outlineWidthRange.contains(width) else { throw AIToolError("style.outline_width must be 0 to 12.") }
            outlineWidth = width
        }
        if let text = try fields.string("box") { box = .some(try AIColor.parse(text)) }
        if case .some(.some) = outline, case .some(.some) = box {
            throw AIToolError("Give style.outline or style.box, not both: the bar behind the text replaces the outline.")
        }
        // set_text 的 shadow 是开关，AI 顺手写成 true / false 也认：true = 烧录页「白字阴影」那套的颜色。
        if case .bool(let on)? = fields.raw["shadow"] {
            shadow = .some(on ? Self.defaultShadow : nil)
        } else if let text = try fields.string("shadow") {
            shadow = .some(try AIColor.parse(text))
        }
        if case .some(.some) = shadow, case .some(.some) = box {
            throw AIToolError("Give style.shadow or style.box, not both: a shadow goes with an outline, the bar has none.")
        }
        if let text = try fields.string("highlight") { highlight = .some(try AIColor.parse(text)) }
        if let scale = try fields.double("highlight_scale") {
            guard SubtitleWordHighlight.scaleRange.contains(scale) else { throw AIToolError("style.highlight_scale must be 1 to 1.3.") }
            highlightScale = scale
        }
    }

    init() {}

    /// 改了字幕本身的样子（不只是高亮、不只是 reset）。
    var changesLook: Bool {
        position != nil || margin != nil || size != nil || font != nil || bold != nil || color != nil
            || outline != nil || outlineWidth != nil || box != nil || shadow != nil
    }

    var changesHighlight: Bool { highlight != nil || highlightScale != nil }

    /// 字体名按这台 Mac 上烧录能用的字体认（大小写不敏感，回表里的写法）；认不出就报错，列出能用的。
    func resolvingFont(in available: [String]) throws -> AISubtitleStyleChange {
        guard let name = font else { return self }
        guard let match = available.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else {
            let some = available.prefix(40).joined(separator: ", ")
            throw AIToolError("The font \(name) cannot be used for subtitles on this Mac (burning needs a font file SrtFlow can read). Fonts that work: \(some).")
        }
        var resolved = self
        resolved.font = match
        return resolved
    }

    /// 落到一份样式上（burn_subtitles 那一批自带的；edit_subtitles 先取此刻用的那套再调它）。
    func applied(to base: BurnInStyle) -> BurnInStyle {
        var style = base
        if let position { style.position = position }
        if let margin { style.marginVertical = margin }
        if let size { style.fontSize = size }
        if let font { style.fontName = font }
        if let bold { style.bold = bold }
        if let color { style.fillColor = color }
        if case .some(let barColor) = box {
            if let barColor {
                if style.borderStyle != .box { style.outlineWidth = 6 }   // 底条时它是内边距
                style.borderStyle = .box
                style.outlineColor = barColor
            } else if style.borderStyle == .box {
                style.borderStyle = .outline
                style.outlineColor = .black
                style.outlineWidth = 3
            }
        }
        if case .some(let lineColor) = outline {
            if style.borderStyle == .box {
                style.borderStyle = .outline
                style.outlineWidth = 3
            }
            if let lineColor {
                style.outlineColor = lineColor
                if style.outlineWidth == 0 { style.outlineWidth = 3 }
            } else {
                style.outlineWidth = 0
            }
        }
        if let outlineWidth { style.outlineWidth = outlineWidth }
        if case .some(let shadowColor) = shadow {
            if let shadowColor {
                // 阴影只跟描边一起画（预览、烧录都是）：底条模式先回到描边。偏移沿用烧录页「白字阴影」那套的 3。
                if style.borderStyle == .box {
                    style.borderStyle = .outline
                    style.outlineColor = .black
                    style.outlineWidth = 3
                }
                style.shadowColor = shadowColor
                if style.shadowOffset == 0 { style.shadowOffset = 3 }
            } else {
                style.shadowOffset = 0
            }
        }
        return style
    }

    /// edit_subtitles：落到这个工程上（一次 perform 里调）。
    func apply(to state: inout TimelineState, appWide: BurnInStyle) {
        if reset { state.projectSubtitleStyle = nil }
        if changesLook {
            state.projectSubtitleStyle = applied(to: state.subtitleStyle(appWide: appWide))
        }
        if position != nil || margin != nil {
            // 拖框的布局锚定在底部中心，会盖住这里给的位置。
            state.subtitleLayout = nil
            state.translationLayout = nil
        } else if size != nil {
            // 布局的字号倍率会乘在字号上：给了字号，出来的就该是这个字号。
            state.subtitleLayout?.fontScale = 1
            state.translationLayout?.fontScale = 1
        }
        if case .some(let color) = highlight {
            let scale = highlightScale ?? state.subtitleHighlight?.scale ?? SubtitleWordHighlight.defaultScale
            state.subtitleHighlight = color.map { SubtitleWordHighlight(color: $0, scale: scale) }
        } else if let highlightScale {
            state.subtitleHighlight = SubtitleWordHighlight(color: state.subtitleHighlight?.color ?? .yellow, scale: highlightScale)
        }
    }

    /// 回给 AI 看的「这个工程的字幕现在长什么样」（get_subtitles、edit_subtitles 的结果）。
    static func describe(_ state: TimelineState, appWide: BurnInStyle) -> JSONValue {
        let style = state.subtitleStyle(appWide: appWide)
        let layout = state.subtitleLayout
        var object: [String: JSONValue] = [
            "own_style": .bool(state.projectSubtitleStyle != nil),
            "size": .number((style.fontSize * (layout?.fontScale ?? 1)).rounded()),
            "font": .string(style.fontName),
            "bold": .bool(style.bold),
            "color": .string(AIColor.hex(style.fillColor)),
            "highlight": .string(state.subtitleHighlight.map { AIColor.hex($0.color) } ?? "none")
        ]
        if layout != nil {
            object["position"] = "dragged in the preview (a custom spot)"
        } else {
            let row = positions.first { $0.value.row == style.position.row }?.name ?? "bottom"
            object["position"] = .string(style.position.column == 1 ? row : "\(row) \(style.position.column == 0 ? "left" : "right")")
            object["margin"] = .number((Double(style.marginVertical) / Double(BurnInStyle.referenceHeight) * 1000).rounded() / 1000)
        }
        if style.borderStyle == .box {
            object["box"] = .string(AIColor.hex(style.outlineColor))
        } else {
            object["outline"] = .string(style.outlineWidth > 0 ? AIColor.hex(style.outlineColor) : "none")
            object["outline_width"] = .number(style.outlineWidth)
            object["shadow"] = .string(style.shadowOffset > 0 ? AIColor.hex(style.shadowColor) : "none")
        }
        if let highlight = state.subtitleHighlight { object["highlight_scale"] = .number(highlight.scale) }
        return .object(object)
    }
}
