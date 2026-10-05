import Foundation

// MARK: - 关键帧的缓动曲线（纯值）
//
// 管什么：从一帧到**下一帧**那一段用什么曲线（存在 `Keyframe.easing` 上，最后一帧的没用）：linear / easeIn / easeOut /
// easeInOut，2026-10-05 加了 snap / overshoot / spring；进度 0…1 过曲线。曲线函数只有 TextEasing 一份，这里只是挑一条。
// 为什么：AI 做的推镜、位移都是直线插值，看着像机器做的（docs/plans/2026-09-30-export-limiter-and-easing.md）；
// 推近、甩、画中画弹进来要「啪」地到位、冲过头再回来（docs/plans/2026-10-05-editing-aesthetics.md 第四节）。
// 老工程没有这个键 = linear，一个字都不变（`LenientCodableEnum`：不认识的值也回落成 linear）。
// 用在哪：`KeyframeTrack.value(atSourceTime:)` 取值；预览合成带缓动的段按帧加密（KeyframeSliceTimes）；
// AI 的 `set_keyframes easing`（词表 `MCPVocabulary.keyframeEasings` 和这里对账）；检查器的曲线菜单。
// 不管什么：插值本身、切片、存盘的版本登记（VideoEditFormatVersion 的 v27 / v32）。

enum KeyframeEasing: String, CaseIterable, Hashable, Sendable {
    case linear, easeIn, easeOut, easeInOut
    /// 2026-10-05（v32）：急停 = 一出手就几乎到位、余下慢慢收住（推近、甩）；回弹 = 冲过头约 10% 再退回；
    /// 弹簧 = 冲过头约 21%、回摆一两下停住。
    case snap, overshoot, spring

    /// 进度 t（0…1）过曲线。linear 原样返回（不夹、不算：线性插值要和以前逐位一致）。
    func apply(_ t: Double) -> Double {
        switch self {
        case .linear: return t
        case .easeIn: return TextEasing.easeInCubic(t)
        case .easeOut: return TextEasing.easeOutCubic(t)
        case .easeInOut: return TextEasing.easeInOutCubic(t)
        case .snap: return TextEasing.easeOutExpo(t)
        case .overshoot: return TextEasing.easeOutBack(t)
        case .spring: return TextEasing.spring(t)
        }
    }

    /// 曲线会冲过下一帧的值（回弹、弹簧）：取值的地方要自己夹住不能越界的量（不透明度、宽高），
    /// 算全程极值的地方要按 `maximumOvershoot` 放宽（`KeyframeTrack.lowestReachedValue`）。
    var overshoots: Bool { self == .overshoot || self == .spring }

    /// 冲过头最多越出这一段落差的多少（弹簧约 0.21、回弹约 0.10，往大取）。
    static let maximumOvershoot = 0.25

    /// 只有 v32 才认识的三条：只认 v31 的旧版按宽容解码退成直线，随手一存曲线就没了。
    var isVersion32: Bool { self == .snap || self == .overshoot || self == .spring }
}

extension KeyframeEasing: LenientCodableEnum {
    static var decodingFallback: KeyframeEasing { .linear }
}
