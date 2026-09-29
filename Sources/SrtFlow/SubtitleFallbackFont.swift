import CoreText
import Foundation

// MARK: - 回退到系统私有的字体时，换一个每台 Mac 都有的
//
// 管什么：字幕样式的字体里没有的字（Helvetica 里的中文），CoreText 回退到苹方。苹方完整版是按需下载的字体资源
// （/System/Library/AssetsV2/…/PingFang.ttc）；没下载的 Mac（CI 的机器就是）上 CoreText 回退到系统私有的那份
// （/System/Library/PrivateFrameworks/…/Reserved/PingFangUI.ttc）—— 预览照样是中文，烧录的 libass 却用不了它、画成方框
// （2026-09-29，docs/bugfixes/2026-09-29-chinese-burns-as-boxes-without-pingfang.md）。这时换成下面这几个每台 Mac 都在
// /System/Library/Fonts 里的字体（第一个字全都有的）：预览用它画，烧录在这几个字前后写 `\fn` 点名它（SrtFlowCore 的
// SubtitleASSText）。回退到的是公开的字体（下载了苹方的 Mac）就不换：预览和烧录照旧是苹方，什么都不变。
// 认「私有」看字体文件在哪，不看族名：按名字要「PingFang SC」拿到的就是私有那份，族名照样报「PingFang SC」。
// 不管什么：字号比例（SubtitleFontScale）、ASS 标签怎么写（SubtitleASSText）。

enum SubtitleFallbackFont {
    /// 每台 Mac 都有、libass 用得了的中日韩字体，按这个顺序挑：冬青黑体简繁日都有，黑体补冬青没有的字，韩文用 Apple SD Gothic Neo。
    static let builtIn = ["Hiragino Sans GB", "Heiti SC", "Heiti TC", "Hiragino Sans", "Apple SD Gothic Neo"]

    /// libass 用不了的字体：文件在系统私有的框架里（系统界面用的那份，不在能列举的字体里），或者族名以点开头，或者没有文件。
    static func isPrivate(_ font: CTFont) -> Bool {
        guard let url = CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL else { return true }
        return url.path.contains("/PrivateFrameworks/") || (CTFontCopyFamilyName(font) as String).hasPrefix(".")
    }

    /// 这几个字（UTF-16）全都有的第一个内置字体：族名（写进 `\fn`）和 PostScript 名（预览用）；都没有是 nil（只好照旧）。
    static func builtInFont(covering units: [UInt16]) -> (family: String, postScriptName: String)? {
        guard !units.isEmpty else { return nil }
        for family in builtIn {
            let font = CTFontCreateWithName(family as CFString, 12, nil)
            guard CTFontCopyFamilyName(font) as String == family, !isPrivate(font) else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: units.count)
            if CTFontGetGlyphsForCharacters(font, units, &glyphs, units.count) {
                return (family, CTFontCopyPostScriptName(font) as String)
            }
        }
        return nil
    }
}
