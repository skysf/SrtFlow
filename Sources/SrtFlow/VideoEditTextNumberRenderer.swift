import CoreGraphics
import CoreText
import Foundation

// MARK: - 老虎机：按位滚的数字带
//
// 每一个数字位是一条竖着的数字带，裁剪在自己那一格里。带上此刻露出两个数字：
// 当前这个往上移出去，下一个从底下补进来。轮位、空白格、每一格此刻占几成宽都由
// `NumberOdometer`（VideoEditTextOdometer.swift）给 —— 这里只照着画。
//
// ## 为什么排版是定版的
//
// 滚动**只改每一位的轮位，不改字符串**。字符串每帧都换的话，位数一变整行就
// 重排，数字会一边滚一边横着挪。定版之后位槽的 x 固定 —— 只有某一位在起点或终点
// 不存在时，它那一格滚向空白、宽度跟着收（排版在属性串上收它的步进；居中和右对齐
// 右边不动，左对齐左边不动），于是首帧就是起始值、末帧就是终值，中间是连着的。
//
// ## 为什么必须等宽数字
//
// 比例数字里 `1` 比 `8` 窄。位槽的宽度是按最宽的数字算的格距，不等宽的话
// 带上滚过 `1` 的时候会左右晃出格子。等宽在 `TextTypesetter` 的属性串上排。

enum NumberWheelDrawing {

    /// 画一层（描边或填充各调一次）。
    ///
    /// `paint` 非 nil 时走**裁剪模式**：字形只用来收裁剪区，颜色由 `paint`
    /// 刷进去（渐变填充是这么画的）。为 nil 时用当前的绘制模式直接画。
    static func draw(
        _ layout: TextLayout, odometer: OdometerFrame,
        paint: ((CGRect) -> Void)?, into context: CGContext
    ) {
        guard let digits = digitGlyphs(layout.font),
              let metrics = TextTypesetter.digitMetrics(layout.font) else { return }
        let pen = Pen(font: layout.font, digits: digits, metrics: metrics,
                      paint: paint, ink: layout.inkBounds, context: context)

        for line in layout.lines {
            for glyph in line.glyphs {
                guard let cell = odometer.cells[glyph.characterIndex] else {
                    // 前后缀、小数点、两头都在的千分位逗号：不滚，照常画。
                    pen.draw([glyph.glyph], at: [glyph.position])
                    continue
                }
                switch cell {
                case .digit(let wheel, let blank):
                    drawDigit(glyph, wheel: wheel, blank: blank, width: cell.width, line: line, pen: pen)
                case .rider(_, let side):
                    drawRider(glyph, reveal: cell.width, side: side, line: line, pen: pen)
                }
            }
        }
    }

    /// 一位数字：裁剪在自己那一格里，画带上此刻露着的（至多）两格，空白那格不画。
    ///
    /// `width` < 1：这一位正滚向空白（或从空白滚出来）。它的步进在排版里收窄了，但字形仍在
    /// 自己原来那一格（`TextTypesetter.placeCollapsing` 摆回去的），裁剪区也照整格裁 ——
    /// 于是它是在原地滚走，旁边的字从它让出来的地方挪过去。
    private static func drawDigit(
        _ glyph: TextLayout.Glyph, wheel: Double, blank: Int?, width: Double,
        line: TextLayout.Line, pen: Pen
    ) {
        guard width > 0 else { return }  // 整格收起来了：这一位此刻不存在
        let pitch = pen.metrics.pitch
        // 定版串里这个数字已经被 `centerDigits` 居中过，倒推回格子左边。
        let templateAdvance = pen.metrics.advances[glyph.glyph] ?? pitch
        let center = glyph.position.x - (pitch - templateAdvance) / 2 + pitch / 2
        // 一格 = 这一行的行高。带上相邻两个数字正好差一格。
        let step = rowHeight(line)
        let base = wheel.rounded(.down)
        let offset = (wheel - base) * step

        var glyphs: [CGGlyph] = []
        var positions: [CGPoint] = []
        // 当前这格往上移出去 `offset`，下一格从底下补进来。带上滚过的每个数字各自居中 ——
        // 不居中的话，窄的 `1` 会贴在格子左边，滚过去时明显一顿。
        for (cell, dy) in [(base, offset), (base + 1, offset - step)] where Int(cell) != blank {
            let digit = pen.digits[digitIndex(cell)]
            glyphs.append(digit)
            positions.append(CGPoint(
                x: center - (pen.metrics.advances[digit] ?? pitch) / 2,
                y: glyph.position.y + dy
            ))
        }
        guard !glyphs.isEmpty else { return }
        pen.context.saveGState()
        pen.context.clip(to: CGRect(
            x: center - pitch / 2 - 0.5, y: line.baselineY - line.descent, width: pitch + 1, height: step
        ))
        pen.draw(glyphs, at: positions)
        pen.context.restoreGState()
    }

    /// 跟着一位滚进滚出的符号（千分位逗号、负号）：在这一行的格子里上下挪，横向和数字一样
    /// 留在原地。
    private static func drawRider(
        _ glyph: TextLayout.Glyph, reveal: Double, side: Double, line: TextLayout.Line, pen: Pen
    ) {
        guard reveal > 0 else { return }
        var item = glyph.glyph
        var size = CGSize.zero
        CTFontGetAdvancesForGlyphs(pen.font, .horizontal, &item, &size, 1)
        let advance = Double(size.width)
        let x = glyph.position.x
        let step = rowHeight(line)
        pen.context.saveGState()
        // 只有上下两条边要裁（滚出这一行就看不见了）；左右放宽，别切到字形探出步进的那一点。
        pen.context.clip(to: CGRect(
            x: x - step, y: line.baselineY - line.descent, width: advance + 2 * step, height: step
        ))
        pen.draw([glyph.glyph], at: [CGPoint(x: x, y: glyph.position.y + side * (1 - reveal) * step)])
        pen.context.restoreGState()
    }

    private static func rowHeight(_ line: TextLayout.Line) -> Double {
        max(1, line.ascent + line.descent)
    }

    /// 轮位 → 0…9。轮位可能是负的（带子往下转、或者从空白格起步），
    /// 缓动的浮点误差也可能擦出 -0.0000001，所以取正余数而不是裸 `%`。
    private static func digitIndex(_ value: Double) -> Int {
        let raw = Int(value.truncatingRemainder(dividingBy: 10))
        return ((raw % 10) + 10) % 10
    }

    /// 一次 `draw` 里不变的那几样。
    private struct Pen {
        var font: CTFont
        var digits: [CGGlyph]
        var metrics: (pitch: Double, advances: [CGGlyph: Double])
        var paint: ((CGRect) -> Void)?
        var ink: CGRect
        var context: CGContext

        func draw(_ glyphs: [CGGlyph], at positions: [CGPoint]) {
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
