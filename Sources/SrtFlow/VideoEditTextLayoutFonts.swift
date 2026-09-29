import CoreText
import Foundation

// MARK: - 一次排版用到的字体表：主字体 + Core Text 回退出来的字体
//
// 管什么：每个字形是哪个字体的。主字体里没有的字（emoji、主字体不带的汉字）Core Text 排版时按级联表换一个字体
// 来排，run 上带着那个字体，字形号是**那个字体**的；画的时候必须用同一个字体 —— 拿主字体去画别的字体的字形号
// 就是乱码（2026-09-29 婚礼工程：Snell Roundhand 下的 ✨ 画成一个像 ĩ 的字形）。
// 彩色字形（Apple Color Emoji）描边和裁剪两道画不了（没有轮廓），TextDrawing 按这里的标记跳过 / 改成实画。
// 不管什么：排版本身（TextTypesetter）、怎么画（TextDrawing）。

struct TextLayoutFonts: Equatable {
    /// 第 0 个是主字体（样式里选的那一款）；后面是排版时回退到的字体，按出现顺序。
    private(set) var fonts: [CTFont]
    private var colorFlags: [Bool]

    init(main: CTFont) {
        fonts = [main]
        colorFlags = [Self.hasColorGlyphs(main)]
    }

    /// 主字体：数字元件的等宽格子、包围盒都按它算。
    var main: CTFont { fonts[0] }

    /// 第 `index` 个字体；下标坏了退回主字体（别崩在画字上）。
    subscript(index: Int) -> CTFont { fonts[fonts.indices.contains(index) ? index : 0] }

    /// 第 `index` 个字体是不是彩色字形（emoji）。
    func isColor(_ index: Int) -> Bool { colorFlags[colorFlags.indices.contains(index) ? index : 0] }

    /// 这个 run 的字体在表里的下标；不在就加进去。
    mutating func index(of font: CTFont) -> Int {
        if let index = fonts.firstIndex(where: { CFEqual($0, font) }) { return index }
        fonts.append(font)
        colorFlags.append(Self.hasColorGlyphs(font))
        return fonts.count - 1
    }

    static func hasColorGlyphs(_ font: CTFont) -> Bool {
        CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs)
    }

    static func == (lhs: TextLayoutFonts, rhs: TextLayoutFonts) -> Bool {
        lhs.fonts.count == rhs.fonts.count && zip(lhs.fonts, rhs.fonts).allSatisfy { CFEqual($0, $1) }
    }
}
