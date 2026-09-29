import Foundation

// MARK: - 逐词高亮：正在说的那个词长什么样
//
// 管什么：高亮的颜色和放大多少（工程上存一份，视频编辑器的 `TimelineState.subtitleHighlight`，nil = 不高亮），
// 以及烧录时那个词在 ASS 里前后加什么标签。预览（BurnInSubtitleOverlay）按同一份颜色和倍数画；此刻亮哪个词
// 两边都问 `SubtitleTimeSlicing`（烧录每一段的高亮就是段起点那一刻的高亮）。
// 不管什么：词的时间（SubtitleCueWords.swift）。方案第 38、54 条（docs/plans/2026-09-27-mcp.md）。

public struct SubtitleWordHighlight: Codable, Hashable, Sendable {
    /// 正在说的那个词的颜色。
    public var color: SubtitleColor
    /// 那个词放大多少，1 = 不放大。放大时那一行跟着微微变宽（整行居中，别的词会挪一点）。
    public var scale: Double

    public static let scaleRange = 1.0...1.3
    public static let defaultScale = 1.1

    public init(color: SubtitleColor = .yellow, scale: Double = defaultScale) {
        self.color = color
        self.scale = min(max(scale, Self.scaleRange.lowerBound), Self.scaleRange.upperBound)
    }

    /// 一段纯文字写成 ASS 的字：`ranges` 里的词换色、放大，词后面 `{\r}` 回到本来的样式；别的字照 `assText` 写。
    /// 越界的、互相重叠的位置不认。
    public func assText(_ plain: String, ranges: [SubtitleTextRange]) -> String {
        let text = plain as NSString
        var result = ""
        var cursor = 0
        for range in ranges.sorted(by: { $0.location < $1.location })
        where range.length > 0 && range.location >= cursor && range.location + range.length <= text.length {
            result += SubtitleSerializer.assText(text.substring(with: NSRange(location: cursor, length: range.location - cursor)))
            result += openingTag
            result += SubtitleSerializer.assText(text.substring(with: NSRange(location: range.location, length: range.length)))
            result += "{\\r}"
            cursor = range.location + range.length
        }
        return result + SubtitleSerializer.assText(text.substring(from: cursor))
    }

    /// `{\1c&HBBGGRR&\1a&HAA&\fscx110\fscy110}`：ASS 的颜色字节序是 BGR，alpha 是反的（00 不透明）。
    var openingTag: String { "{" + overrideTags + "}" }

    /// 花括号里面那几个标签（和点名字体写在同一个 `{…}` 里时用，SubtitleASSText）。
    var overrideTags: String {
        let alpha = Int(((1 - color.opacity) * 255).rounded())
        let red = Int((color.red * 255).rounded())
        let green = Int((color.green * 255).rounded())
        let blue = Int((color.blue * 255).rounded())
        var tag = String(format: "\\1c&H%02X%02X%02X&\\1a&H%02X&", blue, green, red, alpha)
        let percent = Int((scale * 100).rounded())
        if percent != 100 { tag += "\\fscx\(percent)\\fscy\(percent)" }
        return tag
    }
}
