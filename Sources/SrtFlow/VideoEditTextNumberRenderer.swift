import CoreGraphics
import CoreText
import Foundation

// MARK: - 老虎机：按位滚的数字带
//
// 每一个数字位是一条竖着的数字带，裁剪在自己那一格里。带上此刻露出两个数字：
// 当前这个往上移出去，下一个从底下补进来。轮位由 `NumberRoll.wheel(place:local:)`
// 给 —— 整数部分是当前数字，小数部分就是移出去了多少。
//
// ## 为什么排版是定版的
//
// 滚动**只改每一位的轮位，不改字符串**。字符串每帧都换的话，位数一变整行就
// 重排，数字会一边滚一边横着挪。定版之后位槽的 x 全程固定。
//
// ## 为什么必须等宽数字
//
// 比例数字里 `1` 比 `8` 窄。位槽的宽度是按 `0` 的步进算的，不等宽的话
// 带上滚过 `1` 的时候会左右晃出格子。等宽在 `TextTypesetter.makeFont` 里开。

enum NumberWheelDrawing {

    /// 画一层（描边或填充各调一次）。
    ///
    /// `paint` 非 nil 时走**裁剪模式**：字形只用来收裁剪区，颜色由 `paint`
    /// 刷进去（渐变填充是这么画的）。为 nil 时用当前的绘制模式直接画。
    static func draw(
        _ layout: TextLayout, wheels: [Int: Double],
        paint: ((CGRect) -> Void)?, into context: CGContext
    ) {
        guard let digits = digitGlyphs(layout.font),
              let metrics = TextTypesetter.digitMetrics(layout.font) else { return }
        let ink = layout.inkBounds

        for line in layout.lines {
            // 一格的高度 = 这一行的行高。带上相邻两个数字正好差一格。
            let step = max(1, line.ascent + line.descent)
            for glyph in line.glyphs {
                guard let wheel = wheels[glyph.characterIndex] else {
                    // 前后缀、符号、千分位逗号：不滚，照常画。
                    drawGlyphs([glyph.glyph], at: [glyph.position], font: layout.font,
                               paint: paint, ink: ink, into: context)
                    continue
                }
                // 定版串里这个数字已经被 `centerDigits` 居中过，倒推回格子左边。
                let templateAdvance = metrics.advances[glyph.glyph] ?? metrics.pitch
                let cellStart = glyph.position.x - (metrics.pitch - templateAdvance) / 2
                let slot = CGRect(
                    x: cellStart - 0.5,
                    y: line.baselineY - line.descent,
                    width: metrics.pitch + 1,
                    height: step
                )
                let base = wheel.rounded(.down)
                let offset = (wheel - base) * step
                let current = digits[digitIndex(base)]
                let next = digits[digitIndex(base + 1)]

                context.saveGState()
                context.clip(to: slot)
                drawGlyphs(
                    [current, next],
                    at: [
                        // 带上滚过的每个数字各自居中 —— 不居中的话，窄的 `1`
                        // 会贴在格子左边，滚过去时明显一顿。
                        CGPoint(x: centered(current, from: cellStart, metrics: metrics),
                                y: glyph.position.y + offset),
                        CGPoint(x: centered(next, from: cellStart, metrics: metrics),
                                y: glyph.position.y + offset - step),
                    ],
                    font: layout.font, paint: paint, ink: ink, into: context
                )
                context.restoreGState()
            }
        }
    }

    private static func centered(
        _ glyph: CGGlyph, from cellStart: Double,
        metrics: (pitch: Double, advances: [CGGlyph: Double])
    ) -> Double {
        cellStart + (metrics.pitch - (metrics.advances[glyph] ?? metrics.pitch)) / 2
    }

    /// 轮位 → 0…9。`wheel` 理论上非负（终值取的是绝对值），
    /// 但缓动的浮点误差可能擦出 -0.0000001，所以取正余数而不是裸 `%`。
    private static func digitIndex(_ value: Double) -> Int {
        let raw = Int(value.truncatingRemainder(dividingBy: 10))
        return ((raw % 10) + 10) % 10
    }

    private static func drawGlyphs(
        _ glyphs: [CGGlyph], at positions: [CGPoint], font: CTFont,
        paint: ((CGRect) -> Void)?, ink: CGRect, into context: CGContext
    ) {
        var items = glyphs
        var points = positions
        guard let paint else {
            CTFontDrawGlyphs(font, &items, &points, items.count, context)
            return
        }
        context.saveGState()
        context.setTextDrawingMode(.clip)
        CTFontDrawGlyphs(font, &items, &points, items.count, context)
        paint(ink)
        context.restoreGState()
    }

    /// `0`…`9` 的字形。格距和各自的步进由 `TextTypesetter.digitMetrics` 给 ——
    /// 排版和绘制必须用**同一份**，否则数字带和它的格子对不齐。
    private static func digitGlyphs(_ font: CTFont) -> [CGGlyph]? {
        var characters: [UniChar] = Array("0123456789".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        guard CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count) else {
            return nil
        }
        return glyphs
    }
}
