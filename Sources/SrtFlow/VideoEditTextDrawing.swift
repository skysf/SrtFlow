import CoreGraphics
import CoreText
import Foundation
import SrtFlowCore

// MARK: - 文字的各道绘制
//
// 从 VideoEditTextRenderer.swift 拆出来：那边管画布、包络、模糊和坐标系，
// 这边管"底板、描边、填充、字形"这四道怎么落笔。
//
// ## 画的顺序，以及为什么是这个顺序
//
//   底板 → （投影 ⨁ 描边 ⨁ 填充）
//
// 括号里三样收在**一个透明层**里：投影设在层外面，于是整块字（含描边）投出
// **一个**影子。不这么做的话，描边和填充会各投一个，边上是一圈脏边。
//
// 底板**在层外面**，不参与投影：底板自己就是个实心块，再投一个影子只会让
// 深色底板边上糊一圈更深的东西。需要底板带影子的话，用形状标注垫一层。
//
// ## 逐字动画为什么要拆成一个字形一次绘制
//
// 每个字形的不透明度和位移都不一样，整行批量喂位置做不到。代价是绘制调用
// 多了 N 倍，但标题就几十个字，而且**只在动画进行中**才走这条路
//（`PerGlyph == nil` 时仍是整行批量）。

enum TextDrawing {

    /// 底板。不参与投影（见文件头）。
    static func background(
        _ style: TextStyle, layoutBox: CGRect, scale: Double, into context: CGContext
    ) {
        guard let background = style.background, background.color.opacity > 0 else { return }
        let rect = layoutBox.insetBy(
            dx: -max(0, background.paddingX * scale),
            dy: -max(0, background.paddingY * scale)
        )
        let radius = min(max(0, background.cornerRadius * scale), min(rect.width, rect.height) / 2)
        context.saveGState()
        context.setFillColor(cgColor(background.color))
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
        context.restoreGState()
    }

    /// 描边。走**两倍线宽**再被填充盖掉内半边，于是露在外面的正好是用户设的
    /// 宽度。直接用 `.fillStroke` 的话线宽是跨在字形轮廓上的，一半吃进字里，
    /// 细字体会被描边啃掉一圈。
    ///
    /// `wipe`：描边生长时只画扫到的那一段（`nil` = 整条都画）。
    static func stroke(
        _ style: TextStyle, layout: TextLayout, scale: Double,
        animation: TextAnimationState, wipe: Double?, clipBounds: CGRect,
        into context: CGContext
    ) {
        guard let stroke = style.stroke, stroke.width > 0, stroke.color.opacity > 0 else { return }
        context.saveGState()
        if let wipe { clipWipe(wipe, bounds: clipBounds, into: context) }
        context.setLineWidth(max(0.1, stroke.width * scale * 2))
        context.setLineJoin(.round)
        context.setLineCap(.round)
        context.setStrokeColor(cgColor(stroke.color))
        context.setTextDrawingMode(.stroke)
        glyphs(layout, animation: animation, into: context)
        context.restoreGState()
    }

    /// 填充。纯色直接画；渐变先用字形把裁剪区收成"字的形状"，再往里刷渐变。
    ///
    /// `extraAlpha`：描边生长时填充要晚一点才化进来。
    static func fill(
        _ style: TextStyle, layout: TextLayout,
        animation: TextAnimationState, extraAlpha: Double, into context: CGContext
    ) {
        guard extraAlpha > 0 else { return }
        switch style.fill {
        case .solid(let color):
            guard color.opacity > 0 else { return }
            context.saveGState()
            context.setAlpha(extraAlpha)
            context.setFillColor(cgColor(color))
            context.setTextDrawingMode(.fill)
            glyphs(layout, animation: animation, into: context)
            context.restoreGState()

        case .gradient(let from, let to, let angleDegrees):
            let ink = layout.inkBounds
            guard !ink.isNull, ink.width > 0 || ink.height > 0 else { return }
            guard let gradient = CGGradient(
                colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                colors: [cgColor(from), cgColor(to)] as CFArray,
                locations: [0, 1]
            ) else { return }

            // 逐字动画时每个字形的不透明度都不同，"所有字形一起进裁剪区、
            // 刷一次渐变"就不成立了 —— 只能一个字形一次裁剪一次刷。
            // 渐变的几何仍按**整块墨迹**算，于是每个字形拿到的是它在整块
            // 渐变里本该有的那一段颜色，而不是各自从头到尾渐变一遍。
            if animation.digitWheels != nil {
                NumberWheelDrawing.draw(
                    layout, wheels: animation.digitWheels ?? [:],
                    paint: { ink in
                        paint(gradient, ink: ink, angleDegrees: angleDegrees, into: context)
                    },
                    into: context
                )
                return
            }
            if let perGlyph = animation.perGlyph {
                for line in layout.lines {
                    for glyph in line.glyphs {
                        let alpha = glyphAlpha(glyph, perGlyph: perGlyph)
                        guard alpha > 0 else { continue }
                        context.saveGState()
                        context.setAlpha(alpha * extraAlpha)
                        context.setTextDrawingMode(.clip)
                        draw([glyph], offsetY: glyphOffsetY(glyph, perGlyph: perGlyph),
                             font: layout.font, into: context)
                        paint(gradient, ink: ink, angleDegrees: angleDegrees, into: context)
                        context.restoreGState()
                    }
                }
                return
            }

            context.saveGState()
            context.setAlpha(extraAlpha)
            context.setTextDrawingMode(.clip)
            glyphs(layout, animation: animation, into: context)
            paint(gradient, ink: ink, angleDegrees: angleDegrees, into: context)
            context.restoreGState()
        }
    }

    // MARK: - 字形

    /// 画字形。没有逐字调制时整行批量喂位置（Core Text 的快路径）；
    /// 有调制时一个字形一次，各带各的不透明度和位移。
    private static func glyphs(
        _ layout: TextLayout, animation: TextAnimationState, into context: CGContext
    ) {
        // 老虎机优先：数字带自己要按位裁剪，逐字错峰那套（每个字形一个
        // 不透明度）在它上面没有意义 —— 一位数字同时露着两个字形。
        // 整层的不透明度/缩放/模糊照常生效，它们是上下文级的。
        if let wheels = animation.digitWheels {
            NumberWheelDrawing.draw(layout, wheels: wheels, paint: nil, into: context)
            return
        }
        guard let perGlyph = animation.perGlyph else {
            for line in layout.lines where !line.glyphs.isEmpty {
                draw(line.glyphs, offsetY: 0, font: layout.font, into: context)
            }
            return
        }
        for line in layout.lines {
            for glyph in line.glyphs {
                let alpha = glyphAlpha(glyph, perGlyph: perGlyph)
                guard alpha > 0 else { continue }
                context.saveGState()
                context.setAlpha(alpha)
                draw([glyph], offsetY: glyphOffsetY(glyph, perGlyph: perGlyph),
                     font: layout.font, into: context)
                context.restoreGState()
            }
        }
    }

    /// 打字机是**硬切**：进度过半才画，不淡不移。半透明的字在打字机效果里
    /// 看起来像渲染出错，而不像"正在打出来"。
    private static func glyphAlpha(
        _ glyph: TextLayout.Glyph, perGlyph: TextAnimationState.PerGlyph
    ) -> Double {
        let progress = perGlyph.progress(forCharacter: glyph.characterIndex)
        return perGlyph.hardCut ? (progress >= 0.5 ? 1 : 0) : progress
    }

    private static func glyphOffsetY(
        _ glyph: TextLayout.Glyph, perGlyph: TextAnimationState.PerGlyph
    ) -> Double {
        guard !perGlyph.hardCut, perGlyph.riseY != 0 else { return 0 }
        let progress = perGlyph.progress(forCharacter: glyph.characterIndex)
        // `riseY` 是 y 向下为正（UI 直觉），这里的画布 y 向上 —— 取负。
        return -(1 - progress) * perGlyph.riseY
    }

    private static func draw(
        _ items: [TextLayout.Glyph], offsetY: Double, font: CTFont, into context: CGContext
    ) {
        guard !items.isEmpty else { return }
        var glyphs = items.map(\.glyph)
        var positions = items.map { CGPoint(x: $0.position.x, y: $0.position.y + offsetY) }
        CTFontDrawGlyphs(font, &glyphs, &positions, glyphs.count, context)
    }

    // MARK: - 零件

    /// 横向擦除：只露出 `bounds` 左起 `progress` 那么宽的一条。
    static func clipWipe(_ progress: Double, bounds: CGRect, into context: CGContext) {
        let width = bounds.width * min(max(progress, 0), 1)
        guard width > 0 else {
            // 宽度为 0 时给一个空裁剪区：`clip(to: .zero)` 在某些实现下是 no-op，
            // 那会让"还没扫到"的一帧把整块字都画出来。
            context.clip(to: CGRect(x: bounds.minX, y: bounds.minY, width: 0.0001, height: 0.0001))
            return
        }
        context.clip(to: CGRect(x: bounds.minX, y: bounds.minY, width: width, height: bounds.height))
    }

    static func paint(
        _ gradient: CGGradient, ink: CGRect, angleDegrees: Double, into context: CGContext
    ) {
        // 0° 从左到右，90° 从上到下（屏幕意义上的下 = y 向上时的负方向）。
        let radians = angleDegrees * .pi / 180
        let direction = CGVector(dx: cos(radians), dy: -sin(radians))
        let extent = abs(ink.width * direction.dx) + abs(ink.height * direction.dy)
        let mid = CGPoint(x: ink.midX, y: ink.midY)
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: mid.x - direction.dx * extent / 2, y: mid.y - direction.dy * extent / 2),
            end: CGPoint(x: mid.x + direction.dx * extent / 2, y: mid.y + direction.dy * extent / 2),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
    }

    static func cgColor(_ color: SubtitleColor) -> CGColor {
        CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.opacity)
    }
}
