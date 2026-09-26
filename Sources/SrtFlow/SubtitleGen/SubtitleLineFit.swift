import Foundation
import SrtFlowCore

// 一行字幕在画面上放得下几个字号宽（2026-09-26）—— 生成字幕时按它封顶，竖屏自动更短，
// 生成出来的每一条都不会被折成两行。
//
// 管什么：可用宽度只从 `SubtitleFrameGeometry` 取（预览拖框、就地编辑用的同一份换算，不算第二遍），
// 除以原文轨的字号（全局样式 × 工程布局的倍率），再给描边、字距留一点余量。
// 不管什么：一行按什么数字数、上限多少（SrtFlowCore 的 `SubtitleLineMeasure` / `SubtitleSegmentationConfig`）。
// 生成之后再改字号 / 边距，已生成的字幕不重排 —— 放不下时由渲染自动折行。

enum SubtitleLineFit {
    /// 给描边、字距和「粗体英文比估的宽」留的余量。
    static let safety = 0.95

    /// - Parameters:
    ///   - style: 全局烧录样式（预览同一份）。
    ///   - layout: 原文轨的工程布局覆盖（`TimelineState.subtitleLayout`），nil = 按全局样式。
    ///   - renderSize: 画面尺寸（只用它的宽高比）。
    static func ems(style: BurnInStyle, layout: SubtitleLayout?, renderSize: CGSize) -> Double {
        guard renderSize.width > 0, renderSize.height > 0 else { return .infinity }
        let reference = Double(BurnInStyle.referenceHeight)
        let box = CGSize(width: reference * renderSize.width / renderSize.height, height: reference)
        let geometry = SubtitleFrameGeometry(boxSize: box, style: style, layout: layout, blockHeight: 0)
        let fontSize = style.fontSize * (layout?.fontScale ?? 1)
        guard fontSize > 0 else { return .infinity }
        return Double(geometry.frameRect.width) / fontSize * safety
    }
}
