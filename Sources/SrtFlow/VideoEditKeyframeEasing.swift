import Foundation

// MARK: - 关键帧的缓动曲线（纯值）
//
// 管什么：从一帧到**下一帧**那一段用什么曲线（存在 `Keyframe.easing` 上，最后一帧的没用）：linear / easeIn / easeOut /
// easeInOut；进度 0…1 过曲线。曲线函数只有 TextEasing 一份，这里只是挑一条。
// 为什么：AI 做的推镜、位移都是直线插值，看着像机器做的（docs/plans/2026-09-30-export-limiter-and-easing.md）。
// 老工程没有这个键 = linear，一个字都不变（`LenientCodableEnum`：不认识的值也回落成 linear）。
// 用在哪：`KeyframeTrack.value(atSourceTime:)` 取值；预览合成带缓动的段按帧加密（KeyframeSliceTimes）；
// AI 的 `set_keyframes easing`（词表 `MCPVocabulary.keyframeEasings` 和这里对账）；检查器的曲线菜单。
// 不管什么：插值本身、切片、存盘的版本登记（VideoEditFormatVersion 的 v27）。

enum KeyframeEasing: String, CaseIterable, Hashable, Sendable {
    case linear, easeIn, easeOut, easeInOut

    /// 进度 t（0…1）过曲线。linear 原样返回（不夹、不算：线性插值要和以前逐位一致）。
    func apply(_ t: Double) -> Double {
        switch self {
        case .linear: return t
        case .easeIn: return TextEasing.easeInCubic(t)
        case .easeOut: return TextEasing.easeOutCubic(t)
        case .easeInOut: return TextEasing.easeInOutCubic(t)
        }
    }
}

extension KeyframeEasing: LenientCodableEnum {
    static var decodingFallback: KeyframeEasing { .linear }
}
