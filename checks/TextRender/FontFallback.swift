import CoreGraphics
import CoreText
import Foundation

// 主字体里没有的字（emoji、主字体不带的汉字）：Core Text 排版时回退到别的字体，字形号是那个字体的，画的时候
// 必须用同一个字体（Sources/SrtFlow/VideoEditTextLayoutFonts.swift）。修之前所有字形都拿主字体画，Snell Roundhand
// 下的 ✨ 画成一个像 ĩ 的字形（2026-09-29 婚礼工程 BUG-10，docs/bugfixes/2026-09-29-text-fallback-glyphs-drawn-with-main-font.md）。
//
// 断言两层：① 排版：✨ 那个字形记的是 Apple Color Emoji、字形号就是它的；② 渲染：用 Snell Roundhand 画「✨」和把主字体
// 直接设成 Apple Color Emoji 画「✨」，墨迹几乎重合（交并比 ≥ 0.85）；「甜」在 Snell Roundhand 下也要和它回退到的那款
// 中文字体画出来的一样。修之前 ① 里字形号对但字体是主字体，② 的交并比不到一半（画的是主字体里同号的另一个字形）。

private func fallbackOverlay(_ text: String, font: String, stroke: Bool = false) -> TextOverlay {
    var style = TextStyle.default
    style.fontName = font
    style.fontSize = 300
    style.shadow = nil
    style.fill = .solid(.white)
    style.stroke = stroke ? TextStroke(color: .white, width: 6) : nil
    return TextOverlay(text: text, timelineStart: 0, duration: 1, centerX: 0.5, centerY: 0.5, boxWidth: 0.9, style: style)
}

/// 画布坐标上的墨迹集合（alpha > 0 的像素）。
private func inkSet(_ rendered: RenderedText) -> Set<Int> {
    guard let mask = alphaMask(rendered.image) else { return [] }
    var ink: Set<Int> = []
    for y in 0..<mask.height {
        for x in 0..<mask.width where mask.alpha[y * mask.width + x] > 0 {
            ink.insert((Int(rendered.origin.y) + y) * Int(canvas.width) + Int(rendered.origin.x) + x)
        }
    }
    return ink
}

private func overlap(_ a: Set<Int>, _ b: Set<Int>) -> Double {
    let union = a.union(b).count
    return union == 0 ? 0 : Double(a.intersection(b).count) / Double(union)
}

func runFontFallbackChecks() {
    // ① 排版：✨ 的字形记着回退到的字体和它的字形号。
    let layout = TextTypesetter.layout(fallbackOverlay("night ✨", font: "Snell Roundhand"), canvas: canvas)
    let glyphs = layout.lines.flatMap(\.glyphs)
    guard let sparkle = glyphs.last else {
        check(false, "「night ✨」排不出字形")
        return
    }
    check(glyphs.first?.fontIndex == 0, "拉丁字母用主字体（fontIndex 0）")
    check(sparkle.fontIndex != 0, "✨ 不在 Snell Roundhand 里，字形要记成回退字体的（fontIndex \(sparkle.fontIndex)）")
    let fallback = layout.fonts[sparkle.fontIndex]
    checkEqual(CTFontCopyFamilyName(fallback) as String, "Apple Color Emoji", "✨ 回退到 Apple Color Emoji")
    check(layout.fonts.isColor(sparkle.fontIndex), "Apple Color Emoji 记成彩色字形")
    check(!layout.fonts.isColor(0), "主字体不是彩色字形")
    var unit = Array("✨".utf16)
    var expected = CGGlyph(0)
    CTFontGetGlyphsForCharacters(fallback, &unit, &expected, 1)
    checkEqual(sparkle.glyph, expected, "字形号就是回退字体里 ✨ 的字形号")

    // ② 渲染：和把主字体直接设成回退字体画出来的一样。
    func ink(_ text: String, font: String, stroke: Bool = false) -> Set<Int> {
        guard let rendered = TextRenderer.render(fallbackOverlay(text, font: font, stroke: stroke), canvas: canvas) else { return [] }
        return inkSet(rendered)
    }
    let viaSnell = ink("✨", font: "Snell Roundhand")
    let viaEmoji = ink("✨", font: "Apple Color Emoji")
    check(viaEmoji.count > 200, "Apple Color Emoji 画得出 ✨（\(viaEmoji.count) 个像素）")
    let emojiOverlap = overlap(viaSnell, viaEmoji)
    check(emojiOverlap >= 0.85, "Snell Roundhand 下的 ✨ 要用 Apple Color Emoji 画：和直接用它画的交并比 \(emojiOverlap)（修之前画的是主字体里同号的字形）")

    let hanLayout = TextTypesetter.layout(fallbackOverlay("甜", font: "Snell Roundhand"), canvas: canvas)
    if let han = hanLayout.lines.flatMap(\.glyphs).first {
        let hanFont = CTFontCopyFamilyName(hanLayout.fonts[han.fontIndex]) as String
        check(han.fontIndex != 0, "「甜」不在 Snell Roundhand 里，回退到 \(hanFont)")
        let hanOverlap = overlap(ink("甜", font: "Snell Roundhand"), ink("甜", font: hanFont))
        check(hanOverlap >= 0.85, "Snell Roundhand 下的「甜」要用 \(hanFont) 画：交并比 \(hanOverlap)")
    } else {
        check(false, "「甜」排不出字形")
    }

    // 描边下 emoji 照样在（描边那一道跳过它、填充那一道画它），拉丁字母照样有描边。
    let strokedEmoji = ink("✨", font: "Snell Roundhand", stroke: true)
    check(overlap(strokedEmoji, viaEmoji) >= 0.85, "带描边时 ✨ 照样画出来、且没被描边糊掉：交并比 \(overlap(strokedEmoji, viaEmoji))")
    let plainLatin = ink("n", font: "Snell Roundhand")
    let strokedLatin = ink("n", font: "Snell Roundhand", stroke: true)
    check(strokedLatin.count > plainLatin.count, "描边让拉丁字母的墨迹变多（\(plainLatin.count) → \(strokedLatin.count)）")
}
