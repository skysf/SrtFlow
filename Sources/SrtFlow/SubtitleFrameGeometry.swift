import Foundation
import SrtFlowCore

/// 预览画面上「字幕块占哪块矩形」的唯一算法。
///
/// 两个消费端：布局拖框（`SubtitleFrameCanvas`）和就地编辑的输入框
/// （`SubtitlePreviewEditLayer`，双击字幕后浮在块下面）。**这段换算不许算第二遍**
/// —— 一个按 1080 基准算、另一个照着眼睛估，拖框和输入框立刻错位，而且样式
/// （九宫格位置、边距）一改就各错各的。
///
/// 坐标系与全局合同一致：1080p 虚拟画布基准像素，按 `boxHeight / 1080` 换算到
/// 预览框（见 docs/architecture/subtitle-track-visibility-and-layout.md）。
struct SubtitleFrameGeometry {
    let boxSize: CGSize
    let style: BurnInStyle
    /// 工程级布局覆盖，没有就从全局样式推导。
    let layout: SubtitleLayout?
    /// 当前字幕文本块的实测高度（`BurnInSubtitleOverlay` 回报）。
    let blockHeight: Double

    var scale: Double {
        boxSize.height / Double(BurnInStyle.referenceHeight)
    }

    /// 当前生效布局：还没有覆盖时从全局样式推导（第一次拖动就落成覆盖）。
    /// 覆盖的锚定固定为底部中心 —— 全局样式是九宫格时，推导只近似垂直位置。
    var effectiveLayout: SubtitleLayout {
        if let layout { return layout }
        let blockUnits = blockHeight / max(scale, 0.0001)
        let reference = Double(BurnInStyle.referenceHeight)
        let bottom: Double
        switch style.position.row {
        case 0: bottom = Double(style.marginVertical)
        case 1: bottom = (reference - blockUnits) / 2
        default: bottom = reference - Double(style.marginVertical) - blockUnits
        }
        return SubtitleLayout(
            marginLeft: style.marginHorizontal,
            marginRight: style.marginHorizontal,
            marginBottom: Int(max(0, bottom).rounded()),
            fontScale: 1
        )
    }

    /// 字幕块在预览框里的矩形（左上角原点）。
    var frameRect: CGRect {
        let layout = effectiveLayout
        let left = Double(layout.marginLeft) * scale
        let right = Double(layout.marginRight) * scale
        let bottom = Double(layout.marginBottom) * scale
        let height = max(blockHeight, 24)
        return CGRect(
            x: left,
            y: boxSize.height - bottom - height,
            width: max(boxSize.width - left - right, 30),
            height: height
        )
    }
}
