import CoreGraphics
import CoreText
import Foundation

// MARK: - 文字排版
//
// 把一段文字排成「第几行、每个字形落在哪」。**预览和导出调的是同一份**，
// 所以两边的折行位置、行距、对齐一定一致 —— 这是 text-overlays.md 里那条
// 「两条管线共用一个渲染函数」合同的上半截（下半截是 VideoEditTextRenderer）。
//
// ## 坐标系（最容易写错的地方）
//
// 本文件产出的坐标一律是 **Core Text 原生的 y 轴向上**、原点在版面框
// **左下角**。不转成 UI 习惯的左上原点，是因为渲染时要直接喂给
// `CTFontDrawGlyphs`，中间每多一次翻转就多一个符号写反的机会。
//
// 预览侧不受影响：它拿到的是渲染好的位图，从不碰这里的坐标。
//
// ## 版面框 = 定位框
//
// 文字块的定位框是**版面框**（宽 = 用户设的折行宽度，高 = 排出来的总高），
// 不是字的墨迹范围。所以左对齐的一行短字会靠在框左边，而不是被拉回正中 ——
// 改对齐方式时文字在一个固定的框里移动，这是所有剪辑软件的一致行为。

/// 排好版的一段文字。
struct TextLayout: Equatable {
    /// 一个字形。位置是**基线原点**，在版面框坐标系里（左下原点，y 向上）。
    struct Glyph: Equatable {
        var glyph: CGGlyph
        var position: CGPoint
        /// 这个字形对应原始字符串里的下标。逐字动画按它排序错峰（第二刀用）。
        var characterIndex: Int
    }

    /// 一行。`glyphs` 已按视觉顺序排好。
    struct Line: Equatable {
        var glyphs: [Glyph]
        /// 基线在版面框坐标系里的 y（左下原点）。
        var baselineY: Double
        /// 这一行墨迹的左端 x 与宽度（对齐之后的实际位置）。
        var originX: Double
        var width: Double
        var ascent: Double
        var descent: Double

        static func == (lhs: Line, rhs: Line) -> Bool {
            lhs.glyphs == rhs.glyphs && lhs.baselineY == rhs.baselineY
                && lhs.originX == rhs.originX && lhs.width == rhs.width
                && lhs.ascent == rhs.ascent && lhs.descent == rhs.descent
        }
    }

    /// 版面框尺寸（像素）。宽是用户设的折行宽度，高是排出来的。
    var size: CGSize
    var lines: [Line]
    /// 排版用的字体。渲染和包围盒都要它，避免第二次构造时参数写歪。
    var font: CTFont

    var isEmpty: Bool { lines.allSatisfy { $0.glyphs.isEmpty } }

    /// 第一行基线在版面框里的 y。数字滚动时"这一帧"和"定版"可能行数不同，
    /// 靠它把两者的第一行对齐。
    var firstBaselineY: Double { lines.first?.baselineY ?? 0 }

    /// 墨迹在版面框里的范围（对齐之后）。空文字返回 `.null`。
    ///
    /// 只用于**收紧位图**，不用于定位 —— 定位一律用版面框（见文件头）。
    var inkBounds: CGRect {
        var result = CGRect.null
        for line in lines where !line.glyphs.isEmpty {
            result = result.union(CGRect(
                x: line.originX,
                y: line.baselineY - line.descent,
                width: line.width,
                height: line.ascent + line.descent
            ))
        }
        return result
    }

    static func == (lhs: TextLayout, rhs: TextLayout) -> Bool {
        lhs.size == rhs.size && lhs.lines == rhs.lines
    }
}

enum TextTypesetter {

    /// 按样式造字体。`fontName` 找不到时 Core Text 自己会回退，不额外兜底 ——
    /// 静默换一个字体比画不出来更难查，但报错又救不了用户（工程是别人机器上
    /// 存的），回退至少还能看见字。
    static func makeFont(
        _ style: TextStyle, pixelSize: Double, monospacedDigits: Bool = false
    ) -> CTFont {
        let size = max(1, pixelSize)
        var font = CTFontCreateWithName(style.fontName as CFString, size, nil)
        var traits: CTFontSymbolicTraits = []
        if style.bold { traits.insert(.traitBold) }
        if style.italic { traits.insert(.traitItalic) }
        if !traits.isEmpty {
            // 第四个参数是要设的位，第五个是掩码：只动粗/斜两位，别的保持原样。
            font = CTFontCreateCopyWithSymbolicTraits(font, size, nil, traits, traits) ?? font
        }
        _ = monospacedDigits  // 等宽不靠字体特性，见下面的 `digitMetrics`
        return font
    }

    /// 十个数字的字形步进，以及取最宽那个当**格距**。
    ///
    /// ## 为什么不用字体特性
    ///
    /// 第一版走的是 `kNumberSpacingType` / `kMonospacedNumbersSelector`。
    /// 实测（2026-09-17）：**苹方根本没实现这个特性**，请求是空操作 ——
    /// 它的数字是比例的（100pt 下 `1` 是 40、`8` 是 60），一跳数整行宽度就
    /// 变 20pt，居中的标题会左右晃。而 Helvetica / Arial 这些本来就等宽，
    /// 特性有没有生效根本看不出来，于是这个坑极容易被"在我机器上是好的"盖过去。
    ///
    /// 所以等宽自己排：用 kern 把每个数字撑成同样宽的格子，再把字形居中放进去。
    static func digitMetrics(_ font: CTFont) -> (pitch: Double, advances: [CGGlyph: Double])? {
        var characters: [UniChar] = Array("0123456789".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        guard CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count) else {
            return nil
        }
        var sizes = [CGSize](repeating: .zero, count: glyphs.count)
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphs, &sizes, glyphs.count)
        var advances: [CGGlyph: Double] = [:]
        for (index, glyph) in glyphs.enumerated() { advances[glyph] = Double(sizes[index].width) }
        guard let pitch = advances.values.max(), pitch > 0 else { return nil }
        return (pitch, advances)
    }

    /// 排版。`canvas` 决定 1080p 基准像素的换算系数。
    ///
    /// `text` 可以覆盖 `overlay.text` —— 数字元件每一帧的内容都不一样，
    /// 但样式、框宽、对齐全都照旧。
    static func layout(_ overlay: TextOverlay, canvas: CGSize, text: String? = nil) -> TextLayout {
        let scale = TextOverlay.pixelScale(canvas: canvas)
        let style = overlay.style
        let font = makeFont(
            style, pixelSize: style.fontSize * scale,
            monospacedDigits: overlay.number != nil
        )
        let boxWidth = max(1, overlay.boxWidth * canvas.width)
        let content = text ?? overlay.text

        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return TextLayout(size: CGSize(width: boxWidth, height: 0), lines: [], font: font)
        }

        let metrics = overlay.number != nil ? digitMetrics(font) : nil
        let attributed = attributedString(
            content, style: style, font: font, scale: scale, digitMetrics: metrics
        )
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        let full = CFRange(location: 0, length: 0)

        // 先问一次「这个宽度下要多高」，再按那个高度建 frame。
        // 直接给一个巨大的高度也能排，但 CTFrameGetLineOrigins 是相对 frame
        // **底边**算的，frame 高了多少，所有行就一起往上飘多少。
        var fitRange = CFRange()
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            setter, full, nil,
            CGSize(width: boxWidth, height: .greatestFiniteMagnitude),
            &fitRange
        )
        let height = max(1, ceil(suggested.height))

        let path = CGPath(rect: CGRect(x: 0, y: 0, width: boxWidth, height: height), transform: nil)
        let frame = CTFramesetterCreateFrame(setter, full, path, nil)

        let ctLines = CTFrameGetLines(frame) as? [CTLine] ?? []
        var origins = [CGPoint](repeating: .zero, count: ctLines.count)
        if !ctLines.isEmpty {
            CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        }

        var lines: [TextLayout.Line] = []
        lines.reserveCapacity(ctLines.count)
        for (index, ctLine) in ctLines.enumerated() {
            let origin = origins[index]
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let width = CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading)
            var glyphs: [TextLayout.Glyph] = []
            for run in (CTLineGetGlyphRuns(ctLine) as? [CTRun] ?? []) {
                glyphs.append(contentsOf: extractGlyphs(run, lineOrigin: origin))
            }
            lines.append(TextLayout.Line(
                glyphs: glyphs,
                baselineY: origin.y,
                originX: origin.x,
                width: width,
                ascent: ascent,
                descent: descent
            ))
        }

        if let metrics {
            centerDigits(in: &lines, text: content, metrics: metrics)
        }
        return TextLayout(size: CGSize(width: boxWidth, height: height), lines: lines, font: font)
    }

    /// 把每个数字字形挪到自己格子的正中。
    ///
    /// kern 是加在字形**后面**的，所以撑出格子之后数字是靠左贴着的 ——
    /// 一串 `8` 里夹一个 `1`，那个 `1` 会明显偏左。补半格就正了；
    /// 它后面的字符已经被整格 kern 推开过，不用再动。
    private static func centerDigits(
        in lines: inout [TextLayout.Line], text: String,
        metrics: (pitch: Double, advances: [CGGlyph: Double])
    ) {
        let characters = Array(text)
        for lineIndex in lines.indices {
            for glyphIndex in lines[lineIndex].glyphs.indices {
                let glyph = lines[lineIndex].glyphs[glyphIndex]
                guard characters.indices.contains(glyph.characterIndex),
                      characters[glyph.characterIndex].isNumber,
                      let advance = metrics.advances[glyph.glyph] else { continue }
                lines[lineIndex].glyphs[glyphIndex].position.x += (metrics.pitch - advance) / 2
            }
        }
    }

    /// 把一个 run 里的字形连同绝对位置抄出来。
    ///
    /// 位置要**加上行原点**：`CTRunGetPositions` 给的是相对这一行基线原点的
    /// 偏移，对齐产生的水平位移全在行原点里。
    private static func extractGlyphs(_ run: CTRun, lineOrigin: CGPoint) -> [TextLayout.Glyph] {
        let count = CTRunGetGlyphCount(run)
        guard count > 0 else { return [] }
        let range = CFRange(location: 0, length: count)

        var glyphs = [CGGlyph](repeating: 0, count: count)
        var positions = [CGPoint](repeating: .zero, count: count)
        var indices = [CFIndex](repeating: 0, count: count)
        CTRunGetGlyphs(run, range, &glyphs)
        CTRunGetPositions(run, range, &positions)
        CTRunGetStringIndices(run, range, &indices)

        return (0..<count).map { index in
            TextLayout.Glyph(
                glyph: glyphs[index],
                position: CGPoint(
                    x: lineOrigin.x + positions[index].x,
                    y: lineOrigin.y + positions[index].y
                ),
                characterIndex: indices[index]
            )
        }
    }

    /// 段落属性：对齐、行距倍数、字距。
    private static func attributedString(
        _ text: String, style: TextStyle, font: CTFont, scale: Double,
        digitMetrics: (pitch: Double, advances: [CGGlyph: Double])?
    ) -> CFAttributedString {
        var alignment: CTTextAlignment = {
            switch style.alignment {
            case .leading: return .left
            case .center: return .center
            case .trailing: return .right
            }
        }()
        var lineHeightMultiple = CGFloat(max(0.1, style.lineSpacing))
        let settings = [
            CTParagraphStyleSetting(
                spec: .alignment,
                valueSize: MemoryLayout<CTTextAlignment>.size,
                value: &alignment
            ),
            CTParagraphStyleSetting(
                spec: .lineHeightMultiple,
                valueSize: MemoryLayout<CGFloat>.size,
                value: &lineHeightMultiple
            ),
        ]
        let paragraph = CTParagraphStyleCreate(settings, settings.count)

        var attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTParagraphStyleAttributeName: paragraph,
        ]
        let baseKern = style.letterSpacing * scale
        if abs(baseKern) > 0.001 {
            attributes[kCTKernAttributeName] = baseKern
        }
        let result = NSMutableAttributedString(
            string: text,
            attributes: attributes.reduce(into: [NSAttributedString.Key: Any]()) {
                $0[NSAttributedString.Key($1.key as String)] = $1.value
            }
        )
        if let digitMetrics {
            applyDigitPitch(to: result, text: text, baseKern: baseKern, metrics: digitMetrics)
        }
        return result as CFAttributedString
    }

    /// 逐个数字加 kern，把它撑成 `pitch` 那么宽的格子。
    ///
    /// 在**属性串**上做而不是排完版再挪：这样行宽、折行、对齐全都自动算对，
    /// 排完再挪只能挪字形，整行的宽度还是错的。
    private static func applyDigitPitch(
        to string: NSMutableAttributedString, text: String, baseKern: Double,
        metrics: (pitch: Double, advances: [CGGlyph: Double])
    ) {
        guard let font = string.attribute(
            NSAttributedString.Key(kCTFontAttributeName as String), at: 0, effectiveRange: nil
        ) else { return }
        let ctFont = font as! CTFont
        var utf16Offset = 0
        for character in text {
            let length = character.utf16.count
            defer { utf16Offset += length }
            guard character.isNumber else { continue }
            var unit = Array(String(character).utf16)
            var glyph = CGGlyph(0)
            guard CTFontGetGlyphsForCharacters(ctFont, &unit, &glyph, 1),
                  let advance = metrics.advances[glyph] else { continue }
            string.addAttribute(
                NSAttributedString.Key(kCTKernAttributeName as String),
                value: baseKern + (metrics.pitch - advance),
                range: NSRange(location: utf16Offset, length: length)
            )
        }
    }
}
