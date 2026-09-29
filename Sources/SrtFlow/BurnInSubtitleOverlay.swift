import SwiftUI
import SrtFlowCore

// MARK: - 叠在画面上的字幕

/// 按当前样式把一句字幕画在画面上。
///
/// 这是**近似**效果，不是 libass 的输出。SwiftUI 的 Text 画不了描边，所以用八个
/// 方向的副本垫在下面充当描边 —— 在实际会用到的描边宽度（1080p 基准 1～6 px）下
/// 看起来足够接近。字号、边距都按 1080 基准换算到画面框的实际尺寸。
/// 视频编辑器的预览、AI 的「看」（AIFrameComposer）也用它画字幕轨，所以单独一个文件。
///
/// 逐词高亮（2026-09-28，方案第 38 条）：`highlights` 里的词按 `highlight` 换色、放大 —— 和烧录的 ASS
/// （`SubtitleWordHighlight.assText`）同一份位置、颜色和倍数。描边那八份副本也要放大那个词（不然描边错位），
/// 只是不换色。
///
/// 字的大小按 libass 的口径（2026-09-29，SubtitleFontScale）：同一个字号，libass 画出来的字只有 CoreText 的 71%–100%
/// （看字体），以前预览一直比成片大。
struct BurnInSubtitleOverlay: View {
    let text: String
    let style: BurnInStyle
    let scale: Double
    let boxSize: CGSize
    /// 工程级布局覆盖（视频编辑器的拖框产物，SrtFlowCore/SubtitleLayout）。
    /// 有它时锚定固定为底部中心、边距/字号倍率全听它的 —— 与 ASS 侧
    /// `assStyle(layout:)` 是同一份合同。烧录工具的预览不传（nil）。
    var layout: SubtitleLayout? = nil
    /// 此刻正在说的词在 `text` 里的位置（`SubtitleTimeSlicing.display`）和怎么高亮；烧录工具的预览不传。
    var highlights: [SubtitleTextRange] = []
    var highlight: SubtitleWordHighlight? = nil
    /// 文本块实测尺寸的回报（字幕拖框要用块高定框）。
    var onBlockSize: ((CGSize) -> Void)? = nil

    /// 八个方向，对角线用 0.707 让描边圆一点。
    private static let outlineOffsets: [CGPoint] = [
        CGPoint(x: 1, y: 0), CGPoint(x: -1, y: 0),
        CGPoint(x: 0, y: 1), CGPoint(x: 0, y: -1),
        CGPoint(x: 0.707, y: 0.707), CGPoint(x: -0.707, y: 0.707),
        CGPoint(x: 0.707, y: -0.707), CGPoint(x: -0.707, y: -0.707)
    ]

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        ZStack(alignment: alignment) {
            Color.clear
            block
                .padding(.leading, leadingPad)
                .padding(.trailing, trailingPad)
                .padding(.bottom, bottomPad)
                .padding(.top, topPad)
        }
        .frame(width: boxSize.width, height: boxSize.height)
        .allowsHitTesting(false)
        .onPreferenceChange(SubtitleBlockSizeKey.self) { size in
            onBlockSize?(size)
        }
    }

    private var block: some View {
        strokedText
            .padding(boxPadding)
            .background { boxBackground }
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: SubtitleBlockSizeKey.self, value: proxy.size)
                }
            }
            .frame(maxWidth: usableWidth, alignment: frameAlignment)
    }

    private var leadingPad: Double {
        if let layout { return Double(layout.marginLeft) * scale }
        return style.position.column == 0 ? horizontalMargin : 0
    }

    private var trailingPad: Double {
        if let layout { return Double(layout.marginRight) * scale }
        return style.position.column == 2 ? horizontalMargin : 0
    }

    private var bottomPad: Double {
        if let layout { return Double(layout.marginBottom) * scale }
        return style.position.row == 0 ? verticalMargin : 0
    }

    private var topPad: Double {
        guard layout == nil else { return 0 }
        return style.position.row == 2 ? verticalMargin : 0
    }

    private var strokedText: some View {
        ZStack {
            if outlineRadius > 0.3 {
                ForEach(Self.outlineOffsets.indices, id: \.self) { index in
                    let offset = Self.outlineOffsets[index]
                    baseText(coloringHighlight: false)
                        .foregroundStyle(style.outlineColor.swiftUIColor)
                        .offset(x: offset.x * outlineRadius, y: offset.y * outlineRadius)
                }
            }
            baseText(coloringHighlight: true).foregroundStyle(style.fillColor.swiftUIColor)
        }
        .shadow(
            color: shadowOffset > 0 ? style.shadowColor.swiftUIColor : .clear,
            radius: 0,
            x: shadowOffset,
            y: shadowOffset
        )
    }

    private func baseText(coloringHighlight: Bool) -> some View {
        styledText(coloringHighlight: coloringHighlight)
            .tracking(style.letterSpacing * scale)
            .multilineTextAlignment(textAlignment)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 字本身：按每一段实际用到的字体缩到烧录（libass）画出来的大小（SubtitleFontScale：同一个字号，libass 把它当行高、
    /// 这里把它当 em，不缩的话预览比成片大 15%–40%）；正在说的词放大（描边的副本也放大）、`coloringHighlight` 时换色。
    private func styledText(coloringHighlight: Bool) -> Text {
        let whole = text as NSString
        let runs = SubtitleFontScale.runs(text, style: style)
        let lit = highlight == nil ? [] : highlights
            .filter { $0.length > 0 && $0.location >= 0 && $0.location + $0.length <= whole.length }
            .map { NSRange(location: $0.location, length: $0.length) }
        // 切点：每一段字体的边界 + 每个亮着的词的边界。
        var cuts: Set<Int> = [0, whole.length]
        for range in runs.map(\.range) + lit { cuts.formUnion([range.location, range.location + range.length]) }
        let sorted = cuts.filter { $0 >= 0 && $0 <= whole.length }.sorted()
        var result = Text(verbatim: "")
        for (start, end) in zip(sorted, sorted.dropFirst()) where end > start {
            let run = runs.first { NSLocationInRange(start, $0.range) }
            let isLit = lit.contains { NSLocationInRange(start, $0) }
            var piece = Text(whole.substring(with: NSRange(location: start, length: end - start))).font(font(
                named: run?.fontName ?? style.fontName, scaledBy: (run?.scale ?? 1) * (isLit ? highlight?.scale ?? 1 : 1)
            ))
            if isLit, coloringHighlight, let highlight { piece = piece.foregroundStyle(highlight.color.swiftUIColor) }
            result = result + piece
        }
        return result
    }

    private func font(named name: String, scaledBy factor: Double) -> Font {
        var result = Font.custom(name, size: style.fontSize * (layout?.fontScale ?? 1) * scale * factor)
        if style.bold { result = result.weight(.bold) }
        if style.italic { result = result.italic() }
        return result
    }

    /// 描边模式才有描边；底框模式下 libass 不画描边。
    private var outlineRadius: Double {
        style.borderStyle == .outline ? style.outlineWidth * scale : 0
    }

    private var shadowOffset: Double {
        style.borderStyle == .outline ? style.shadowOffset * scale : 0
    }

    /// 底框模式下 outlineWidth 是内边距、outlineColor 是底框颜色。
    private var boxPadding: Double {
        style.borderStyle == .box ? max(0, style.outlineWidth * scale) : 0
    }

    @ViewBuilder
    private var boxBackground: some View {
        if style.borderStyle == .box {
            style.outlineColor.swiftUIColor
        }
    }

    private var horizontalMargin: Double { Double(style.marginHorizontal) * scale }
    private var verticalMargin: Double { Double(style.marginVertical) * scale }

    /// 两侧边距同时决定长句在哪里换行（布局覆盖时左右可以不对称）。
    private var usableWidth: Double {
        if layout != nil {
            return max(20, boxSize.width - leadingPad - trailingPad)
        }
        return max(20, boxSize.width - 2 * horizontalMargin)
    }

    private var alignment: Alignment {
        if layout != nil { return .bottom }
        switch (style.position.column, style.position.row) {
        case (0, 0): return .bottomLeading
        case (1, 0): return .bottom
        case (2, 0): return .bottomTrailing
        case (0, 1): return .leading
        case (1, 1): return .center
        case (2, 1): return .trailing
        case (0, 2): return .topLeading
        case (1, 2): return .top
        default: return .topTrailing
        }
    }

    private var frameAlignment: Alignment {
        guard layout == nil else { return .center }
        switch style.position.column {
        case 0: return .leading
        case 2: return .trailing
        default: return .center
        }
    }

    private var textAlignment: TextAlignment {
        guard layout == nil else { return .center }
        switch style.position.column {
        case 0: return .leading
        case 2: return .trailing
        default: return .center
        }
    }
}

/// BurnInSubtitleOverlay 文本块实测尺寸（字幕拖框定高用）。
///
/// **合并时不许让零盖掉量出来的值**：SwiftUI 合并时，没写这个值的兄弟节点也会给出默认值 `.zero`，
/// `value = nextValue()` 于是被它们盖成零 —— 块高一直是 0，拖框退回最小高度 24 点、贴在块底。单行字幕时
/// 正好像是框对了，一直没人发现；原文、译文叠成两行之后，框只框住底下那行（译文），点原文、拖原文全落到
/// 译文上（2026-09-26 案例 docs/bugfixes/2026-09-26-stacked-subtitle-frame-lands-on-translation.md）。
/// 同文件夹里 `InlineEditorSizeKey` 早就是这么写的。
private struct SubtitleBlockSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}
