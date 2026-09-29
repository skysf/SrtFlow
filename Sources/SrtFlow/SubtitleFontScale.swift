import CoreText
import Foundation
import SrtFlowCore

// MARK: - 预览上的字幕按 libass 的字号大小画
//
// 管什么：同一个字号，烧录（libass）和预览（CoreText / SwiftUI）画出来的字不一样大：libass 把字号当**行高** —— 字体
// OS/2 表里的 usWinAscent + usWinDescent 撑满字号；CoreText 把字号当 **em**。于是烧出来的字小一截，比例是
// UPM / (usWinAscent + usWinDescent)：Helvetica 0.851、苹方 0.714、Avenir Next 0.732、黑体 1.0。
// 2026-09-29 用 vendor/ffmpeg 真烧一帧量：Helvetica 大写字母高 0.850、中文（Helvetica 里没有，回退到苹方）0.716，和算的对得上；
// 用户那边的 AI 量到成片字幕是预览的 71%（docs/bugfixes/2026-09-29-subtitle-preview-bigger-than-burn.md）。
// 预览就按**每一段字实际用到的字体**的比例缩：字体里有的字用它自己的比例，没有的（Helvetica 里的中文）照 CoreText 的回退
// 找到那个字体、按它的比例 —— libass 回退到的是同一个字体（按比例量出来一致）。
// 「实际用到的字体」连粗细算在内：粗体画的是家族里真的粗体（Hiragino Sans GB 的 W6 是 0.806、W3 是 0.861；Helvetica-Bold
// 0.839），libass 选的也是它，所以比例按粗体那一款量 —— 接口只收整份样式，漏不掉粗体。
// 不管什么：怎么画（BurnInSubtitleOverlay）、一行放多少（SubtitleLineFit 用 `lineScale`）。

enum SubtitleFontScale {
    /// 一段字用到的字体和它的比例。
    struct Run: Equatable {
        /// 在字里的位置（UTF-16）。
        var range: NSRange
        /// 这一段用哪个字体画：字体里有的字就是样式里的那个名字，回退的是回退到的字体的 PostScript 名。
        var fontName: String
        /// em 是字号的多少（libass 画出来的大小 / CoreText 同字号的大小）。
        var scale: Double
    }

    /// 这个字体（按粗体 / 斜体选到的那一款）的 em 是字号的多少：UPM / (usWinAscent + usWinDescent)；读不到表就当 1。
    static func scale(ofFont name: String, bold: Bool, italic: Bool) -> Double {
        cache.withLock { cached in
            let key = "\(name)|\(bold)|\(italic)"
            if let known = cached[key] { return known }
            let value = measuredScale(face(name, bold: bold, italic: italic))
            cached[key] = value
            return value
        }
    }

    /// 一段字按实际用到的字体分成几截（挨着的同一个字体并成一截）。
    static func runs(_ text: String, style: BurnInStyle) -> [Run] {
        let base = CTFontCreateWithName(style.fontName as CFString, 12, nil)
        let baseScale = scale(ofFont: style.fontName, bold: style.bold, italic: style.italic)
        let units = Array(text.utf16)
        var runs: [Run] = []
        var index = 0
        while index < units.count {
            let length = units[index] >= 0xD800 && units[index] <= 0xDBFF && index + 1 < units.count ? 2 : 1
            var glyphs = [CGGlyph](repeating: 0, count: length)
            let covered = CTFontGetGlyphsForCharacters(base, Array(units[index..<(index + length)]), &glyphs, length)
            var name = style.fontName
            var ratio = baseScale
            if !covered {
                let fallback = CTFontCreateForString(base, text as CFString, CFRange(location: index, length: length))
                name = CTFontCopyPostScriptName(fallback) as String
                ratio = scale(ofFont: name, bold: style.bold, italic: style.italic)
            }
            if let last = runs.last, last.fontName == name, last.range.location + last.range.length == index {
                runs[runs.count - 1].range.length += length
            } else {
                runs.append(Run(range: NSRange(location: index, length: length), fontName: name, scale: ratio))
            }
            index += length
        }
        return runs
    }

    /// 算一行放得下多少时用的比例：样式里的字体和它的中文回退里画得**大**的那个（保守，放得下就一定放得下）。
    static func lineScale(style: BurnInStyle) -> Double {
        let chinese = runs("中文", style: style).map(\.scale)
        return ([scale(ofFont: style.fontName, bold: style.bold, italic: style.italic)] + chinese).max() ?? 1
    }

    // MARK: 内部

    private static let cache = Locked<[String: Double]>([:])

    /// 粗体 / 斜体选家族里真的那一款（预览的 `.weight(.bold)`、libass 的 Bold 都是这么选的）；没有斜体的家族只按粗体选
    /// （斜体是斜切出来的，量度和正体一样）；都没有就是它本身。
    private static func face(_ name: String, bold: Bool, italic: Bool) -> CTFont {
        let base = CTFontCreateWithName(name as CFString, 12, nil)
        var wanted: CTFontSymbolicTraits = []
        if bold { wanted.insert(.traitBold) }
        if italic { wanted.insert(.traitItalic) }
        guard !wanted.isEmpty else { return base }
        if let styled = CTFontCreateCopyWithSymbolicTraits(base, 0, nil, wanted, wanted) { return styled }
        if bold, let styled = CTFontCreateCopyWithSymbolicTraits(base, 0, nil, .traitBold, .traitBold) { return styled }
        return base
    }

    private static func measuredScale(_ font: CTFont) -> Double {
        let units = Double(CTFontGetUnitsPerEm(font))
        guard units > 0, let table = CTFontCopyTable(font, CTFontTableTag(kCTFontTableOS2), []) as Data?, table.count >= 78 else { return 1 }
        let winAscent = Double(Int(table[74]) << 8 | Int(table[75]))
        let winDescent = Double(Int(table[76]) << 8 | Int(table[77]))
        guard winAscent + winDescent > 0 else { return 1 }
        return units / (winAscent + winDescent)
    }
}

/// 一个带锁的小盒子（预览、AI 的「看」、导出前量一行放多少可能在不同线程上问）。
private final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
