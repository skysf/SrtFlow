import CoreGraphics
import Foundation
import SrtFlowCore

// MARK: - 文字样式
//
// 与字幕的 `BurnInStyle` **刻意不共用一个类型**：字幕那套是喂给 libass 的
// （九宫格位置、上下边距、ASS 的 BorderStyle），文字是自己用 Core Text 画的，
// 要的是对齐方式、行距、渐变填充、真模糊投影、圆角底板 —— 两边的字段几乎
// 不重叠，硬并成一个类型会让双方都长出一堆「对我没意义」的属性。
//
// 复用的是**零件**：颜色仍是 `SubtitleColor`，字体选择仍走 `FontPickerField`。
//
// 尺寸的基准与字幕一致：所有像素量都按 **1080p 画布**定义，渲染时按
// `canvas.height / 1080` 缩放。这样同一套样式在 720p 和 4K 上占画面的比例
// 完全一样，而预览（小画布）和导出（大画布）也天然对得上 —— 这是
// 「预览所见 = 成片所得」的前提之一。

/// 文字填充：纯色，或两色线性渐变。
///
/// 渐变对「质感」的贡献最大，所以它不是可选项而是填充的一种 ——
/// 做成 `TextStyle.gradient: Gradient?` 的话，就会出现「纯色和渐变同时设着，
/// 谁生效」这种没人答得上来的状态。
enum TextFill: Hashable, Sendable {
    case solid(SubtitleColor)
    /// `angleDegrees`：0 = 从左到右，90 = 从上到下，顺时针。
    case gradient(from: SubtitleColor, to: SubtitleColor, angleDegrees: Double)

    /// 用来兜底的单色（渐变取起点色）。检查器里在两种填充之间切换时，
    /// 靠它保住用户已经调好的颜色而不是跳回白色。
    var primaryColor: SubtitleColor {
        switch self {
        case .solid(let color): return color
        case .gradient(let from, _, _): return from
        }
    }

    var isGradient: Bool {
        if case .gradient = self { return true }
        return false
    }
}

/// 描边。`nil` 表示不描边 —— 用 `width == 0` 表达「关」的话，
/// 关掉再打开时用户上次调的颜色就没地方存了。
struct TextStroke: Hashable, Sendable {
    var color: SubtitleColor
    /// 1080p 基准像素。
    var width: Double

    static let `default` = TextStroke(color: .black, width: 4)
    static let widthRange = 0.5...24.0
}

/// 投影。和字幕那边的硬偏移不同，这里有**真模糊半径** ——
/// Core Graphics 的 shadow 是高斯模糊，libass 给不了。
struct TextShadow: Hashable, Sendable {
    var color: SubtitleColor
    /// 1080p 基准像素。正的 y 是往下。
    var offsetX: Double
    var offsetY: Double
    /// 模糊半径，1080p 基准像素。0 = 硬边投影。
    var blur: Double

    static let `default` = TextShadow(color: .translucentBlack, offsetX: 0, offsetY: 6, blur: 12)
    static let offsetRange = -60.0...60.0
    static let blurRange = 0.0...60.0
}

/// 文字底下的色块。圆角和内边距都是 1080p 基准像素。
struct TextBackground: Hashable, Sendable {
    var color: SubtitleColor
    var cornerRadius: Double
    var paddingX: Double
    var paddingY: Double

    static let `default` = TextBackground(
        color: .translucentBlack, cornerRadius: 12, paddingX: 28, paddingY: 14
    )
    static let cornerRadiusRange = 0.0...120.0
    static let paddingRange = 0.0...160.0
}

/// 多行文字的对齐方式。单行时看不出差别，多行（含自动折行）才有意义。
enum TextBlockAlignment: String, CaseIterable, Identifiable, Hashable, Sendable {
    case leading
    case center
    case trailing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .leading: return "Left"
        case .center: return "Center"
        case .trailing: return "Right"
        }
    }

    var icon: String {
        switch self {
        case .leading: return "text.alignleft"
        case .center: return "text.aligncenter"
        case .trailing: return "text.alignright"
        }
    }
}

/// 一段文字的全部外观。位置、大小、时间不在这里 —— 那些是 `TextOverlay` 的。
struct TextStyle: Hashable, Sendable {
    var fontName: String
    /// 1080p 基准的字号。拖画面上的角手柄改的就是它。
    var fontSize: Double
    var bold: Bool
    var italic: Bool
    var fill: TextFill
    var stroke: TextStroke?
    var shadow: TextShadow?
    var background: TextBackground?
    var alignment: TextBlockAlignment
    /// 行距倍数。1 = 字体自己的行高。
    var lineSpacing: Double
    /// 字距，1080p 基准像素。
    var letterSpacing: Double

    /// 渲染时的换算基准：所有像素量都按这个高度定义。与 `BurnInStyle` 同一个数。
    static let referenceHeight = 1080.0

    static let fontSizeRange = 12.0...400.0
    static let lineSpacingRange = 0.6...3.0
    static let letterSpacingRange = -20.0...80.0

    /// 新建文字的默认样式。
    ///
    /// 字体选 PingFang SC 而不是字幕那边的 Helvetica：标题里出现中文的概率
    /// 远高于字幕样式的使用场景，而 Helvetica 没有中文字形，会掉进系统回退，
    /// 用户看到的第一眼就是"字体设了但没用上"。
    static let `default` = TextStyle(
        fontName: "PingFang SC",
        fontSize: 96,
        bold: true,
        italic: false,
        fill: .solid(.white),
        stroke: nil,
        shadow: TextShadow(color: .translucentBlack, offsetX: 0, offsetY: 4, blur: 10),
        background: nil,
        alignment: .center,
        lineSpacing: 1,
        letterSpacing: 0
    )
}

// MARK: - 存盘
//
// 全部走 `decodeIfPresent` + 默认值：缺键一律回退到 `TextStyle.default` 的同名
// 字段，这样第二刀往样式里加东西时，第一刀存下的工程照样读得进来。

extension TextFill: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, color, from, to, angleDegrees
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "solid"
        if kind == "gradient" {
            self = .gradient(
                from: try c.decodeIfPresent(SubtitleColor.self, forKey: .from) ?? .white,
                to: try c.decodeIfPresent(SubtitleColor.self, forKey: .to) ?? .white,
                angleDegrees: try c.decodeIfPresent(Double.self, forKey: .angleDegrees) ?? 90
            )
        } else {
            self = .solid(try c.decodeIfPresent(SubtitleColor.self, forKey: .color) ?? .white)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .solid(let color):
            try c.encode("solid", forKey: .kind)
            try c.encode(color, forKey: .color)
        case .gradient(let from, let to, let angle):
            try c.encode("gradient", forKey: .kind)
            try c.encode(from, forKey: .from)
            try c.encode(to, forKey: .to)
            try c.encode(angle, forKey: .angleDegrees)
        }
    }
}

extension TextStroke: Codable {
    private enum CodingKeys: String, CodingKey { case color, width }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            color: try c.decodeIfPresent(SubtitleColor.self, forKey: .color) ?? .black,
            width: try c.decodeIfPresent(Double.self, forKey: .width) ?? TextStroke.default.width
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(color, forKey: .color)
        try c.encode(width, forKey: .width)
    }
}

extension TextShadow: Codable {
    private enum CodingKeys: String, CodingKey { case color, offsetX, offsetY, blur }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            color: try c.decodeIfPresent(SubtitleColor.self, forKey: .color) ?? .translucentBlack,
            offsetX: try c.decodeIfPresent(Double.self, forKey: .offsetX) ?? 0,
            offsetY: try c.decodeIfPresent(Double.self, forKey: .offsetY) ?? 0,
            blur: try c.decodeIfPresent(Double.self, forKey: .blur) ?? 0
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(color, forKey: .color)
        try c.encode(offsetX, forKey: .offsetX)
        try c.encode(offsetY, forKey: .offsetY)
        try c.encode(blur, forKey: .blur)
    }
}

extension TextBackground: Codable {
    private enum CodingKeys: String, CodingKey { case color, cornerRadius, paddingX, paddingY }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            color: try c.decodeIfPresent(SubtitleColor.self, forKey: .color) ?? .translucentBlack,
            cornerRadius: try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? 0,
            paddingX: try c.decodeIfPresent(Double.self, forKey: .paddingX) ?? 0,
            paddingY: try c.decodeIfPresent(Double.self, forKey: .paddingY) ?? 0
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(color, forKey: .color)
        try c.encode(cornerRadius, forKey: .cornerRadius)
        try c.encode(paddingX, forKey: .paddingX)
        try c.encode(paddingY, forKey: .paddingY)
    }
}

extension TextBlockAlignment: LenientCodableEnum {
    static var decodingFallback: TextBlockAlignment { .center }
}

extension TextStyle: Codable {
    private enum CodingKeys: String, CodingKey {
        case fontName, fontSize, bold, italic, fill, stroke, shadow, background
        case alignment, lineSpacing, letterSpacing
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = TextStyle.default
        self.init(
            fontName: try c.decodeIfPresent(String.self, forKey: .fontName) ?? fallback.fontName,
            fontSize: try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? fallback.fontSize,
            bold: try c.decodeIfPresent(Bool.self, forKey: .bold) ?? fallback.bold,
            italic: try c.decodeIfPresent(Bool.self, forKey: .italic) ?? fallback.italic,
            fill: try c.decodeIfPresent(TextFill.self, forKey: .fill) ?? fallback.fill,
            // 三个可选装饰：键不在 = 用户就是关着的，**不能**回退到默认值，
            // 否则「我明明关了投影」在重开工程后会自己长回来。
            stroke: try c.decodeIfPresent(TextStroke.self, forKey: .stroke),
            shadow: try c.decodeIfPresent(TextShadow.self, forKey: .shadow),
            background: try c.decodeIfPresent(TextBackground.self, forKey: .background),
            alignment: try c.decodeIfPresent(TextBlockAlignment.self, forKey: .alignment) ?? fallback.alignment,
            lineSpacing: try c.decodeIfPresent(Double.self, forKey: .lineSpacing) ?? fallback.lineSpacing,
            letterSpacing: try c.decodeIfPresent(Double.self, forKey: .letterSpacing) ?? fallback.letterSpacing
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(fontName, forKey: .fontName)
        try c.encode(fontSize, forKey: .fontSize)
        try c.encode(bold, forKey: .bold)
        try c.encode(italic, forKey: .italic)
        try c.encode(fill, forKey: .fill)
        try c.encodeIfPresent(stroke, forKey: .stroke)
        try c.encodeIfPresent(shadow, forKey: .shadow)
        try c.encodeIfPresent(background, forKey: .background)
        try c.encode(alignment, forKey: .alignment)
        try c.encode(lineSpacing, forKey: .lineSpacing)
        try c.encode(letterSpacing, forKey: .letterSpacing)
    }
}
