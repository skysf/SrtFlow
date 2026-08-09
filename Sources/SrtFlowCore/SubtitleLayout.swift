import Foundation

/// 工程级的字幕布局覆盖（预览拖框的产物，docs/architecture/subtitle-language-flow.md
/// 的姊妹合同 subtitle-track-visibility-and-layout.md）。
///
/// 坐标系与 `BurnInStyle` 完全一致：**1080p 虚拟画布基准像素**，libass 按
/// PlayResY=1080 等比缩放，预览按 `boxHeight / 1080` 缩放 —— 同一份数值两边
/// 各自换算，不存在第二种坐标系。
///
/// 语义：一旦存在覆盖，锚定方式固定为**底部中心**（ASS Alignment 2）——
/// 文本块在 [marginLeft, 画布宽−marginRight] 里居中换行，块底边距画面底边
/// marginBottom。全局样式的九宫格 position 从此不再参与该工程的排版；
/// 字体、颜色、描边等其余样式仍然全部来自全局样式。
public struct SubtitleLayout: Codable, Hashable, Sendable {
    /// 左边距（1080p 基准像素）。与右边距一起决定换行宽度。
    public var marginLeft: Int
    /// 右边距（1080p 基准像素）。
    public var marginRight: Int
    /// 文本块底边到画面底边的距离（1080p 基准像素）。ASS 的 MarginV。
    public var marginBottom: Int
    /// 相对全局样式字号的倍率（拖角等比缩放的产物）。
    public var fontScale: Double

    public static let fontScaleRange = 0.3...3.0

    public init(marginLeft: Int, marginRight: Int, marginBottom: Int, fontScale: Double = 1) {
        self.marginLeft = max(0, marginLeft)
        self.marginRight = max(0, marginRight)
        self.marginBottom = max(0, marginBottom)
        self.fontScale = min(
            max(fontScale, Self.fontScaleRange.lowerBound), Self.fontScaleRange.upperBound
        )
    }
}

extension BurnInStyle {

    /// 套上工程级布局覆盖后的 ASS 样式行。layout 为 nil 时就是原样式。
    /// 预览（BurnInSubtitleOverlay）与烧录必须都经由这一份数值 ——
    /// 这是「拖一个框 = 调整整个工程字幕」的合同本体。
    public func assStyle(layout: SubtitleLayout?) -> SubtitleStyle {
        var style = assStyle
        guard let layout else { return style }
        style.alignment = SubtitlePosition.bottomCenter.assAlignment
        style.marginL = layout.marginLeft
        style.marginR = layout.marginRight
        style.marginV = layout.marginBottom
        style.fontSize = fontSize * layout.fontScale
        return style
    }
}
