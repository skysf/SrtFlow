import Foundation
import SrtFlowCore

// MARK: - 形状的入场 / 出场动画
//
// 管什么：形状（线条、长方形、正方形、圆、圆弧）的入场和出场效果的数据、存盘，和「某一刻该怎么画」的求值（纯值）。
// 不管什么：照着求出来的状态怎么画（`ShapeOutline.drawing` 出路径，预览 `ShapePreviewDrawing`、导出 `ShapePNGRenderer` 上色），
// 导出里怎么切段（`ShapeOverlayExport`）。盖一块（模糊 / 马赛克）没有动画。
//
// 2026-10-03（南极工程的报告：「图形只能突然出现、突然消失」）。效果和文字动画同名、同曲线、同时长夹紧（`FadeWindow.clamped`），
// 只收对形状有意义的四种；为什么是这四种、出场为什么是入场倒放，见 docs/architecture/shapes.md「入场 / 出场动画」。

/// 形状的入场 / 出场效果。出场是入场倒着放（同文字动画）。
enum ShapeAnimationKind: String, CaseIterable, Identifiable, Hashable, Sendable {
    case none
    /// 淡入淡出。
    case fade
    /// 弹性缩放：缩着进来，冲过头一点再回弹到位；出场直接收走。
    case pop
    /// 遮罩擦除：从左往右扫出来。
    case wipe
    /// 画出来：线和描边顺着笔顺描出来（线从左端起、长方形从左上角顺时针、圆从 12 点钟顺时针、圆弧从它的起点）；
    /// 实心的顺着同一个方向露出来（长方形从左往右、圆从 12 点钟顺时针扫一圈）。
    case draw

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .fade: return "Fade"
        case .pop: return "Pop"
        case .wipe: return "Wipe"
        case .draw: return "Draw on"
        }
    }
}

struct ShapeAnimation: Hashable, Sendable {
    var entrance: ShapeAnimationKind = .none
    var exit: ShapeAnimationKind = .none
    /// 时间线秒。选了效果才生效，夹紧在读侧做（`window(span:)`）：存的是用户的意图，段被拉长之后动画跟着恢复。
    var entranceDuration = ShapeAnimation.defaultDuration
    var exitDuration = ShapeAnimation.defaultDuration

    static let defaultDuration = 0.6
    /// 同文字动画（`TextAnimation.durationRange`）。
    static let durationRange = 0.1...5.0

    var isEmpty: Bool { entrance == .none && exit == .none }

    /// 这一段真正生效的入 / 出场时长（夹紧之后），和文字、声音、画面渐变共用 `FadeWindow.clamped`。
    func window(span: Double) -> FadeWindow {
        FadeWindow.clamped(
            fadeIn: entrance == .none ? 0 : entranceDuration,
            fadeOut: exit == .none ? 0 : exitDuration,
            span: span
        )
    }
}

/// 某一刻形状该怎么画。默认值就是「不动」。
struct ShapeAnimationState: Equatable, Sendable {
    /// 整个形状的不透明度乘数。
    var opacity = 1.0
    /// 绕形状中心的等比缩放（只缩几何、不缩线宽）。
    var scale = 1.0
    /// 横向擦除：露出可见框左起这么多比例。nil = 不擦。
    var wipe: Double?
    /// 画出来：顺着笔顺画到这么多比例。nil = 整个画。
    var drawn: Double?

    static let identity = ShapeAnimationState()
}

enum ShapeAnimator {
    /// 弹性缩放起手的大小：和文字的 `pop` 在默认强度（0.6）下一样（1 − 0.35 × 0.6）。形状没有强度这个旋钮。
    static let popStartScale = 0.79

    /// 这一刻的动画状态。`timelineTime` 请先经 `TextAnimator.quantize`（预览和导出同一把尺子）。
    static func state(for shape: ShapeAnnotation, at timelineTime: Double) -> ShapeAnimationState {
        let animation = shape.animation
        guard !animation.isEmpty, !shape.kind.isCover else { return .identity }
        let span = max(0.0001, shape.duration)
        let local = timelineTime - shape.timelineStart
        let window = animation.window(span: span)
        // 入场和出场不会重叠（FadeWindow 保证两者之和不超过段长），求值是干净的三段式。
        if window.fadeIn > 0, local < window.fadeIn {
            return state(animation.entrance, reveal: local / window.fadeIn, entering: true)
        }
        if window.fadeOut > 0, local > span - window.fadeOut {
            return state(animation.exit, reveal: (span - local) / window.fadeOut, entering: false)
        }
        return .identity
    }

    /// `reveal`：1 = 完全出来了，0 = 还没出来（出场倒着走）。曲线和文字动画同一份（`TextEasing`）。
    static func state(_ kind: ShapeAnimationKind, reveal: Double, entering: Bool) -> ShapeAnimationState {
        let r = min(max(reveal.isFinite ? reveal : 0, 0), 1)
        var state = ShapeAnimationState()
        switch kind {
        case .none:
            break
        case .fade:
            // 入场先快后慢，出场先慢后快 —— 东西该「被抽走」，不是「慢慢停住」。
            state.opacity = entering ? TextEasing.easeOutCubic(r) : TextEasing.easeInCubic(r)
        case .pop:
            // 入场带回弹（冲过头约 1.1 再退回来），出场 easeIn 直接收走 —— 出场再弹一下像没关紧的弹簧。
            let curve = entering ? TextEasing.easeOutBack(r) : TextEasing.easeInCubic(r)
            state.opacity = TextEasing.easeOutCubic(r)
            state.scale = popStartScale + (1 - popStartScale) * curve
        case .wipe:
            // 线性：擦除和画出来的进度本来就是几何量，加缓动会让扫过的速度忽快忽慢。
            state.wipe = TextEasing.linear(r)
        case .draw:
            state.drawn = TextEasing.linear(r)
        }
        return state
    }
}

// MARK: - 存盘

extension ShapeAnimationKind: LenientCodableEnum {
    static var decodingFallback: ShapeAnimationKind { .none }
}

extension ShapeAnimation: Codable {
    private enum CodingKeys: String, CodingKey {
        case entrance, exit, entranceDuration, exitDuration
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entrance = try c.decodeIfPresent(ShapeAnimationKind.self, forKey: .entrance) ?? .none
        exit = try c.decodeIfPresent(ShapeAnimationKind.self, forKey: .exit) ?? .none
        entranceDuration = try c.decodeIfPresent(Double.self, forKey: .entranceDuration) ?? Self.defaultDuration
        exitDuration = try c.decodeIfPresent(Double.self, forKey: .exitDuration) ?? Self.defaultDuration
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(entrance, forKey: .entrance)
        try c.encode(exit, forKey: .exit)
        try c.encode(entranceDuration, forKey: .entranceDuration)
        try c.encode(exitDuration, forKey: .exitDuration)
    }
}
