import Foundation

// MARK: - 一句字幕写成 ASS 的字：逐词高亮 + 点名字体
//
// 管什么：烧录的一条事件里，字前后加什么标签。两样：
// - 逐词高亮：正在说的词换色、放大（SubtitleWordHighlight）；
// - 点名字体：这台 Mac 上 libass 自己找不到回退字体的字（样式是拉丁字体、字是中文，而苹方没下载 —— 系统私有的那份 libass
//   用不了），App 挑一个每台 Mac 都有的字体、预览也用它画（SubtitleFallbackFont），这里在那几个字前面写 `\fn` 点名它
//   （2026-09-29，docs/bugfixes/2026-09-29-chinese-burns-as-boxes-without-pingfang.md）。
// 高亮的词后面是 `{\r}`（回到样式本来的样子），会把点名的字体一起清掉，所以两样要一起写：每换一种样子就先 `\r`，再加上
// 这一截该有的字体和高亮。没有要点名的字体时，产物和以前逐字一样。
// 不管什么：哪些字要点名、点名哪个（App 的 SubtitleFontScale / SubtitleFallbackFont）、此刻亮哪个词（SubtitleTimeSlicing）。

/// 一截字要用的字体（族名，写进 `\fn`）。位置按 UTF-16。
public struct SubtitleFontOverride: Hashable, Sendable {
    public var range: SubtitleTextRange
    public var family: String

    public init(range: SubtitleTextRange, family: String) {
        self.range = range
        self.family = family
    }
}

public enum SubtitleASSText {
    /// `lit`：亮着的词（`highlight` 为 nil 时不认）；`fonts`：要点名字体的几截。越界、重叠的不认。
    public static func text(
        _ plain: String, highlight: SubtitleWordHighlight?, lit: [SubtitleTextRange], fonts: [SubtitleFontOverride]
    ) -> String {
        let whole = plain as NSString
        func inside(_ range: SubtitleTextRange) -> Bool {
            range.length > 0 && range.location >= 0 && range.location + range.length <= whole.length
        }
        let fonts = fonts.filter { inside($0.range) }
        let lit = highlight == nil ? [] : lit.filter(inside)
        guard !fonts.isEmpty else {
            // 没有要点名的字体：和以前逐字一样。
            if let highlight, !lit.isEmpty { return highlight.assText(plain, ranges: lit) }
            return SubtitleSerializer.assText(plain)
        }
        var cuts: Set<Int> = [0, whole.length]
        for range in fonts.map(\.range) + lit { cuts.formUnion([range.location, range.location + range.length]) }
        let sorted = cuts.sorted()
        var result = ""
        var current: (font: String?, lit: Bool) = (nil, false)
        for (start, end) in zip(sorted, sorted.dropFirst()) where end > start {
            func covers(_ range: SubtitleTextRange) -> Bool { start >= range.location && start < range.location + range.length }
            let font = fonts.first { covers($0.range) }?.family
            let isLit = lit.contains(where: covers)
            if font != current.font || isLit != current.lit {
                var tag = "\\r"
                if let font { tag += "\\fn" + font }
                if isLit, let highlight { tag += highlight.overrideTags }
                result += "{" + tag + "}"
                current = (font, isLit)
            }
            result += SubtitleSerializer.assText(whole.substring(with: NSRange(location: start, length: end - start)))
        }
        return result
    }
}
