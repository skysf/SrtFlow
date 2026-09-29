import CoreText
import Foundation
import SrtFlowCore

// MARK: - 预览上字幕的行框按 libass 摆
//
// 管什么：同一个字号、同一个字，libass 和 CoreText（SwiftUI 的 Text）不只画得一样大要对（`SubtitleFontScale`），
// **一行占多高、基线在行框里哪儿**也不一样：
// - libass 照 VSFilter 的口径，行框的上下量度用字体 OS/2 表的 usWinAscent / usWinDescent，撑满字号：一行高 = 字号，
//   基线在行框顶下面 `字号 × winAscent / (winAscent + winDescent)` 处；
// - CoreText 用 hhea 的 ascent / descent（不含 leading —— 实测 Heiti、Arial 的 leading 3 px、Hiragino 的 43 px 都没进行框）。
// 两套量度一样的字体（Avenir Next、苹方、黑体、Menlo）没有差；不一样的（Helvetica，默认字体；Hiragino Sans GB）差：
// 2026-09-29 拿 vendor/ffmpeg 真烧、预览离屏渲，100 号字 1080p 画布上 Helvetica 正中对齐成片低 8–9 px、顶部低 16–17 px、
// **两行字幕的行距差 14 px**（预览 147 高、成片 161 高），Hiragino Sans GB 底部对齐预览低 8 px。
// 这里算出预览要补多少：行距补多少、字要往下挪多少（顶部 / 底部 / 居中三种对齐各一个数），
// `BurnInSubtitleOverlay` 照着补。一段字里有几个字体（中文回退）时，行的上下量度取各字体里最大的 —— libass 和 CoreText 都这么排。
// 不管什么：怎么画（BurnInSubtitleOverlay）、字有多大（SubtitleFontScale）。

struct SubtitleLineMetrics: Equatable {
    /// libass 排出来的行：基线上面 / 下面各多高（预览像素）。
    var ascentLibass = 0.0
    var descentLibass = 0.0
    /// 预览（CoreText，已经按 `SubtitleFontScale` 缩过字号）排出来的行。
    var ascentPreview = 0.0
    var descentPreview = 0.0

    /// 预览的行距要在默认行距上再加多少，两行之间才和成片一样远（两个渲染器的一行都是「上 + 下」）。
    var lineSpacing: Double {
        (ascentLibass + descentLibass) - (ascentPreview + descentPreview)
    }

    /// 预览的字要往下挪多少（负的往上），才和成片摆在同一处。`row` 是 `SubtitlePosition.row`：
    /// 0 = 底部对齐（最后一行的基线到底边的距离要一样）、2 = 顶部对齐（第一行的基线到顶边的距离要一样）、1 = 居中（取两者的平均）。
    func shift(row: Int) -> Double {
        let top = ascentLibass - ascentPreview
        let bottom = descentPreview - descentLibass
        switch row {
        case 2: return top
        case 1: return (top + bottom) / 2
        default: return bottom
        }
    }

    /// - Parameters:
    ///   - runs: 这一句字每一截实际画它的字体（`SubtitleFontScale.runs`，回退的也算）。
    ///   - text: 这句字本身：只有换行的那一截不算 —— 换行不是字，不进行框（它落在样式的字体里，算进去 Helvetica 遇上纯中文的
    ///     两行，libass 那边的行高会被高估 5 px）。
    ///   - fontSize: 样式的字号换算到预览像素（含布局的字号倍率）。
    static func of(_ runs: [SubtitleFontScale.Run], in text: String, style: BurnInStyle, fontSize: Double) -> SubtitleLineMetrics {
        var result = SubtitleLineMetrics()
        let whole = text as NSString
        for run in runs where whole.substring(with: run.range).contains(where: { !$0.isNewline }) {
            let share = SubtitleFontScale.ascentShare(ofFont: run.fontName, bold: style.bold, italic: style.italic)
            result.ascentLibass = max(result.ascentLibass, fontSize * share)
            result.descentLibass = max(result.descentLibass, fontSize * (1 - share))
            let font = SubtitleFontScale.ctFont(named: run.fontName, size: fontSize * run.scale, bold: style.bold, italic: style.italic)
            result.ascentPreview = max(result.ascentPreview, Double(CTFontGetAscent(font)))
            result.descentPreview = max(result.descentPreview, Double(CTFontGetDescent(font)))
        }
        return result
    }
}
