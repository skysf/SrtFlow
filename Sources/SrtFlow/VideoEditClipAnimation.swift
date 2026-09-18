import CoreGraphics
import Foundation
import SrtFlowCore

// MARK: - 画面段的入场 / 出场动画（预设）
//
// 两个槽：**入场、出场**，各选一种效果，再加一个全局**强度**。
// 与文字那套（`TextAnimation`）是同一个产品概念，落点不同 ——
// 文字由自家渲染器逐帧画，段走 AVFoundation 合成 + ffmpeg 图。
//
// ## 和 `ClipAnimation` 不是一回事（最容易弄混的一点）
//
// - `ClipAnimation`（VideoEditAnimation.swift）＝用户**手打的关键帧轨**，
//   锚在源时间上，线性插值。
// - `ClipPresetAnimation`（本文件）＝**预设**的入/出场，存的是意图
//   （哪种效果 + 多强），每一帧的值由 `ClipAnimator` 现算。
//
// 两者可以同时存在：预设是叠在「关键帧解析出来的基准」上的偏移，
// 不改存下来的摆放值 —— 与文字那条不变量一致（动画跑着时选中框不会飞）。
//
// ## 时长存在哪：`videoFadeInDuration` / `videoFadeOutDuration`
//
// **本结构里没有时长。** In=Fade 就是 v10 就有的「画面渐变」，于是两者共用同一
// 对字段：老工程零迁移（设过渐变的段打开就是 In=Fade），纯 Fade 仍走 ffmpeg 的
// `fade` 快路径不必预渲染，而「同一个头尾时长」也只有一处真值。
// 夹紧继续走 `FadeWindow.clamped`（与声音渐变、文字动画同一份）。

/// 入场 / 出场的效果。成对使用：出场是入场的**连贯延续**，不是原路退回。
enum ClipPresetKind: String, CaseIterable, Identifiable, Hashable, Sendable {
    case none
    /// 淡入淡出。**就是画面渐变**（整层 alpha 斜坡，露出底下那一层）。
    case fade
    /// 上浮：入场从下方浮上来，出场继续向上移出。自带淡变。
    case rise
    /// 弹性缩放：冲过头一点再回弹到位。自带淡变。
    case pop
    /// 缓推：从略大处匀速收到位（无回弹），像慢推镜头。自带淡变。
    case zoom
    /// 遮罩擦除：从左侧扫出来。**不带淡变**（擦除本身就是"露出来"）。
    case wipe

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .fade: return "Fade"
        case .rise: return "Rise"
        case .pop: return "Pop"
        case .zoom: return "Zoom"
        case .wipe: return "Wipe"
        }
    }

    /// 幅度受「强度」控制吗。
    ///
    /// 只有位移/缩放类：`fade` 只有不透明度、`wipe` 的进度是几何量，
    /// 两者调强度都不会有任何变化 —— 界面据此决定露不露那个滑块，
    /// 一个不生效的滑块只会让人以为自己漏设了什么。
    ///
    /// 与 `needsDenseSampling` 目前成员相同但问的是两件事（一个是产品语义、
    /// 一个是斜坡能不能精确重建），别合并。
    var usesIntensity: Bool {
        switch self {
        case .none, .fade, .wipe: return false
        case .rise, .pop, .zoom: return true
        }
    }

    /// 这一种要**逐帧**才画得出来吗。
    ///
    /// 这是导出路由的唯一判据：`.fade` 是纯 alpha 线性斜坡，ffmpeg 自己的
    /// `fade=…:alpha=1` 就能做（`VideoFade.filterSteps`），走轻量路径；
    /// 其余几种要逐帧变换/裁切，ffmpeg 做不了干净的逐帧缩放和透明度插值，
    /// 只能用预览同一套合成预渲染成中间片（`AnimatedClipPrerenderer`）。
    var needsPerFrameRender: Bool {
        switch self {
        case .none, .fade: return false
        case .rise, .pop, .zoom, .wipe: return true
        }
    }
}

/// 一段的预设动画。默认值就是"什么都没设"。
struct ClipPresetAnimation: Hashable, Sendable {
    var entrance: ClipPresetKind = .none
    var exit: ClipPresetKind = .none
    /// 幅度总控 0…1：位移多远、缩多少，统一按它缩放。
    ///
    /// 质感来自缓动曲线和幅度配比这些用户调不出来的东西（见 `ClipAnimator`），
    /// 所以只给一个总控，不摊开每种效果的参数。
    var intensity: Double = 0.6

    static let `default` = ClipPresetAnimation()
    static let intensityRange = 0.0...1.0
    /// 刚选上效果时给的时长（秒）。与文字动画同一个数。
    ///
    /// 用户选了效果却什么都没发生是最糟的第一印象 —— 而时长存的是画面渐变那
    /// 两个字段，默认 0。所以选上效果时要顺手给个能看见的时长（写入侧
    /// `VideoEditProject+ClipAnimation.swift`），选回 None 时再清零。
    static let defaultDuration = 0.6

    /// 两个槽都没设 —— 整条预设路径可以完全跳过。
    ///
    /// **不变量：`kind == .none` ⟺ 那一侧的 `videoFade*Duration == 0`。**
    /// 写入侧两者永远一起改（选上效果给默认时长、选回 None 清零），
    /// 读盘侧靠它把老工程认回来：没有 `presetAnimation` 键但时长 > 0 的，
    /// 就是 v14 及更早那些"只设了画面渐变"的段，一律认作 `.fade`。
    var isEmpty: Bool { entrance == .none && exit == .none }

    /// 有任何一侧要逐帧渲染（导出要不要预渲染看它）。
    /// **注意**：还要配合时长才真正生效，最终判据是 `ClipPreset.effective`。
    var needsPerFrameRender: Bool {
        entrance.needsPerFrameRender || exit.needsPerFrameRender
    }

    /// 任一侧的幅度受强度控制（界面据此决定露不露强度滑块）。
    var usesIntensity: Bool { entrance.usesIntensity || exit.usesIntensity }

    mutating func clampToValidRange() {
        intensity = min(max(intensity.isFinite ? intensity : ClipPresetAnimation.default.intensity,
                            ClipPresetAnimation.intensityRange.lowerBound),
                        ClipPresetAnimation.intensityRange.upperBound)
    }
}

// MARK: - 仲裁：这一段真正生效的入/出场

/// 效果 + 窗口的**唯一收口**。预览、导出、Inspector 提示三处都从这里取，
/// 各算各的一定会在边界条件上分叉。
struct ResolvedClipPreset: Equatable, Sendable {
    var entrance: ClipPresetKind
    var exit: ClipPresetKind
    /// 已经夹紧、且已经做过转场仲裁的头尾时长。
    var window: FadeWindow
    var intensity: Double

    static let none = ResolvedClipPreset(
        entrance: .none, exit: .none, window: .none, intensity: 0
    )

    var isEmpty: Bool { entrance == .none && exit == .none }

    /// 要逐帧渲染吗（导出路由 + 预览要不要走逐片重算）。
    var needsPerFrameRender: Bool {
        entrance.needsPerFrameRender || exit.needsPerFrameRender
    }

    /// 任一侧用了擦除 —— 这一段全程都要挂裁切矩形。
    ///
    /// **不能只在窗口内挂**：裁切是逐片的斜坡，窗口外那一片必须明确给出
    /// "整幅"这个矩形，否则那一片干脆不设裁切，AVFoundation 会把上一片的
    /// 裁切一直保持下去（或者整条斜坡根本挂不上）—— 表现就是擦除完全不生效。
    var usesWipe: Bool { entrance == .wipe || exit == .wipe }

    /// 这一侧的窗口（求值和切片都按边取）。
    func duration(_ edge: FadeEdge) -> Double {
        edge == .fadeIn ? window.fadeIn : window.fadeOut
    }

    func kind(_ edge: FadeEdge) -> ClipPresetKind {
        edge == .fadeIn ? entrance : exit
    }
}

enum ClipPreset {
    /// 这一段最终生效的入/出场。
    ///
    /// 时长与转场仲裁**复用画面渐变的那一份**（`VideoFade.effective` →
    /// `FadeWindow.clamped` + `suppressing`）：接缝上有转场时那条边整个归转场管，
    /// 入/出场动画和画面渐变一样让位，不叠加。窗口被夹成 0 的那一侧，效果也
    /// 跟着归零 —— "选了效果但时长是 0" 与"没选"必须是同一件事，否则
    /// 预览、导出、界面提示会各自给出不同答案。
    static func effective(
        clip: EditClip, hasTransitionBefore: Bool, hasTransitionAfter: Bool
    ) -> ResolvedClipPreset {
        let preset = clip.presetAnimation
        guard !preset.isEmpty else { return .none }
        let window = VideoFade.effective(
            clip: clip,
            hasTransitionBefore: hasTransitionBefore,
            hasTransitionAfter: hasTransitionAfter
        )
        return ResolvedClipPreset(
            entrance: window.fadeIn > 0 ? preset.entrance : .none,
            exit: window.fadeOut > 0 ? preset.exit : .none,
            window: FadeWindow(
                fadeIn: preset.entrance == .none ? 0 : window.fadeIn,
                fadeOut: preset.exit == .none ? 0 : window.fadeOut
            ),
            intensity: min(max(preset.intensity, 0), 1)
        )
    }
}

extension EditClip {
    /// 不考虑转场的生效窗口（Inspector 提示、`needsPerFrameAnimation` 用）。
    /// 真正合成时请走 `ClipPreset.effective` —— 那里才有转场仲裁。
    var presetWindow: FadeWindow {
        FadeWindow.clamped(
            fadeIn: presetAnimation.entrance == .none ? 0 : videoFadeInDuration,
            fadeOut: presetAnimation.exit == .none ? 0 : videoFadeOutDuration,
            span: timelineDuration
        )
    }

    /// 这一段要逐帧渲染吗 —— 导出预渲染的路由判据。
    ///
    /// 保守地**不看转场**：转场仲裁要整条时间线的上下文，而路由只需要知道
    /// "有没有可能要逐帧"。多渲一条中间片只是慢一点，漏渲就是成片没有动画。
    var needsPerFrameAnimation: Bool {
        guard !isAudioOnly else { return false }
        let window = FadeWindow.clamped(
            fadeIn: videoFadeInDuration, fadeOut: videoFadeOutDuration, span: timelineDuration
        )
        if presetAnimation.entrance.needsPerFrameRender, window.fadeIn > 0 { return true }
        if presetAnimation.exit.needsPerFrameRender, window.fadeOut > 0 { return true }
        return false
    }

    /// 关键帧动画或预设动画，任一存在都要走逐帧那条路。
    /// **导出路由、预览切片、黑底轨判据都问它**，别再各自拼 `isAnimated || …`。
    var needsPerFrameRender: Bool { isAnimated || needsPerFrameAnimation }

    /// 摆放框把画布四边都盖住了吗（**纯几何**，不看不透明度）。
    ///
    /// 位移/缩放类动画的"不露边补偿"靠它：盖满画布的段往上浮，下面就会露出
    /// 底下那一层（主轨是黑场、上层轨是主轨画面），所以要按位移量补一点放大
    /// 盖回去；没盖满的段（角落里的 PNG、比例对不上留空的图）本来就没有
    /// "露出来的边"可盖，补了只是一次莫名其妙的缩放。
    ///
    /// 与 `coversCanvasOpaquely` 的区别：那个是叠化路径的判据，要求完全不透明
    /// 且没有动画；这里只问几何。旋转过的段保守算作**没盖满**（转过角之后
    /// 四角会探出画布，补偿量没法用一个标量表达）。
    func placementCoversCanvas(canvas: CGSize) -> Bool {
        guard canvas.width > 0, canvas.height > 0, abs(rotationDegrees) <= 0.01 else { return false }
        let frame = resolvedPlacement(canvas: canvas).frame(in: canvas)
        return frame.minX <= 0.5 && frame.minY <= 0.5
            && frame.maxX >= canvas.width - 0.5 && frame.maxY >= canvas.height - 0.5
    }
}

// MARK: - 存盘（宽容解码，规则同工程文件其他部分）

extension ClipPresetKind: LenientCodableEnum {
    static var decodingFallback: ClipPresetKind { .none }
}

extension ClipPresetAnimation: Codable {
    private enum CodingKeys: String, CodingKey {
        case entrance, exit, intensity
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            entrance: try c.decodeIfPresent(ClipPresetKind.self, forKey: .entrance) ?? .none,
            exit: try c.decodeIfPresent(ClipPresetKind.self, forKey: .exit) ?? .none,
            intensity: try c.decodeIfPresent(Double.self, forKey: .intensity)
                ?? ClipPresetAnimation.default.intensity
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(entrance, forKey: .entrance)
        try c.encode(exit, forKey: .exit)
        try c.encode(intensity, forKey: .intensity)
    }
}
