import CoreGraphics
import Foundation
import SrtFlowCore

// MARK: - 动画求值：时刻 → 这一帧该怎么画
//
// **只算不画。**所有效果最终都落到 `TextAnimationState` 里那几个量上，
// `TextRenderer` 照着画。分开的理由很实在：这一半是纯值函数，自检可以直接
// 逐帧调它比对数值，不用去解码一张位图。
//
// ## 时刻要先钉到工程帧的网格上
//
// 预览和导出都从 `quantize` 进。不量化的话，预览停在两帧之间、成片停在帧上，
// 逐点比对永远差一点点 —— 而"预览所见 = 成片所得"是这整套东西的前提。
//
// ## 入场和出场不会重叠
//
// 时长走 `TextAnimation.window(span:)`（即 `FadeWindow.clamped`），它保证
// 两者之和不超过段长。所以求值可以是干净的三段式：入场 / 中间 / 出场，
// 不需要考虑两种效果同时作用时怎么合成。

/// 某一时刻文字该怎么画。默认值就是"不动"。
struct TextAnimationState: Equatable {
    /// 整层不透明度乘数。
    var opacity: Double = 1
    /// 整块的纵向偏移，画布像素，**y 向下为正**（UI 直觉；渲染时取负）。
    var offsetY: Double = 0
    /// 绕版面框中心的等比缩放。
    var scale: Double = 1
    /// 高斯模糊半径，画布像素。0 = 不模糊。
    var blur: Double = 0
    /// 横向擦除：露出版面框左起这么多比例。nil = 不擦。
    var wipe: Double?
    /// 描边生长。nil = 不用这套（填充照常画）。
    var strokeDraw: StrokeDraw?
    /// 逐字调制。nil = 整块一起动。
    var perGlyph: PerGlyph?
    /// 这一帧要排版的文字。nil = 用 `overlay.text`。数字元件的数值插值靠它。
    var textOverride: String?
    /// 老虎机：定版串里会动的字符此刻怎么画（每一位的轮位、哪一格是空白、占几成宽）。
    /// nil = 不是老虎机。
    var odometer: OdometerFrame?

    struct StrokeDraw: Equatable {
        /// 描边自己的擦除进度 0…1。
        var strokeWipe: Double
        /// 填充的不透明度 0…1（描边扫过之后才化进来）。
        var fillOpacity: Double
    }

    struct PerGlyph: Equatable {
        /// 按**字符下标**取的进度 0…1。字形靠 `TextLayout.Glyph.characterIndex`
        /// 查这张表 —— 不用字形下标，因为连字/组合字会让两者对不上。
        var progress: [Double]
        /// 进度 → 纵向位移的幅度（画布像素，y 向下）。
        var riseY: Double
        /// true = 硬切（进度过半才画，不淡不移）：打字机。
        var hardCut: Bool

        func progress(forCharacter index: Int) -> Double {
            progress.indices.contains(index) ? progress[index] : 1
        }
    }

    /// 什么都不用做 —— 渲染侧可以走完全不带动画的快路径。
    var isIdentity: Bool {
        opacity == 1 && offsetY == 0 && scale == 1 && blur == 0
            && wipe == nil && strokeDraw == nil && perGlyph == nil
            && textOverride == nil && odometer == nil
    }
}

enum TextAnimator {

    /// 把时刻钉到工程帧的网格上。**预览和导出的唯一入口**。
    static func quantize(_ time: Double, frameRate: ProjectFrameRate) -> Double {
        let fps = Double(max(1, frameRate.fps))
        return (time * fps).rounded(.down) / fps
    }

    /// 这一刻的动画状态。`timelineTime` 请先经 `quantize`。
    ///
    /// 要 `frameRate` 是因为呼吸的周期按帧率取整到整数帧 —— 导出的循环段
    /// 只渲一个周期再交给 `loop` 滤镜铺满，周期不是整数帧就会在接缝处跳相位。
    static func state(
        for overlay: TextOverlay, at timelineTime: Double, canvas: CGSize,
        frameRate: ProjectFrameRate
    ) -> TextAnimationState {
        var state = TextAnimationState()
        let span = max(0.0001, overlay.duration)
        let local = timelineTime - overlay.timelineStart

        applyNumberRoll(overlay, local: local, into: &state)

        let animation = overlay.animation
        guard !animation.isEmpty else { return state }

        let window = animation.window(span: span)

        if window.fadeIn > 0, local < window.fadeIn {
            apply(animation.entrance, reveal: local / window.fadeIn,
                  phase: .entrance, overlay: overlay, canvas: canvas, into: &state)
        } else if window.fadeOut > 0, local > span - window.fadeOut {
            apply(animation.exit, reveal: (span - local) / window.fadeOut,
                  phase: .exit, overlay: overlay, canvas: canvas, into: &state)
        }

        applyEmphasis(
            animation.emphasis, local: local, intensity: animation.intensity,
            frameRate: frameRate, into: &state
        )
        return state
    }

    /// 数字滚动：内容随时间变。**与入场/出场正交** —— 前者换的是画什么，
    /// 后者换的是怎么画，两者可以同时生效（一边淡入一边数上去）。
    private static func applyNumberRoll(
        _ overlay: TextOverlay, local: Double, into state: inout TextAnimationState
    ) {
        guard let number = overlay.number else { return }
        switch number.style {
        case .count:
            state.textOverride = number.text(for: number.value(local: local))
        case .odometer:
            // 老虎机的排版是**定版**的（滚动只改每一位的轮位，不改字符串），
            // 于是位槽的位置固定，数字才不会一边滚一边横着挪。只有某一位在起点或
            // 终点不存在时，它那一格滚成空白、宽度跟着收（居中和右对齐右边不动，
            // 左对齐左边不动）—— 首帧就是起始值、末帧就是终值（`NumberOdometer`）。
            state.textOverride = number.settledText
            state.odometer = NumberOdometer(number).frame(local: local)
        }
    }

    private enum Phase {
        case entrance
        case exit
        /// 上浮：入场从下方来（+），出场往上走（−）。**连贯的一段运动**，
        /// 比"原路退回去"更像设计过的。
        var riseSign: Double { self == .entrance ? 1 : -1 }
    }

    // MARK: - 幅度
    //
    // 全部按**字号**算，不按画布尺寸：同一套动画配在 24pt 的小字和 120pt 的
    // 标题上，位移应当各自成比例，否则小字会被甩出画面、大字纹丝不动。

    private static func unit(_ overlay: TextOverlay, canvas: CGSize) -> Double {
        overlay.style.fontSize * TextOverlay.pixelScale(canvas: canvas)
    }

    private static func riseAmplitude(_ overlay: TextOverlay, canvas: CGSize) -> Double {
        unit(overlay, canvas: canvas) * 0.55 * overlay.animation.intensity
    }

    private static func blurAmplitude(_ overlay: TextOverlay, canvas: CGSize) -> Double {
        unit(overlay, canvas: canvas) * 0.22 * overlay.animation.intensity
    }

    private static func popStartScale(_ overlay: TextOverlay) -> Double {
        1 - 0.35 * overlay.animation.intensity
    }

    /// 对焦缩放的幅度：入场从 `1 - amount` 收到 1，出场从 1 涨到 `1 + amount`。
    ///
    /// 比 `pop` 略小 —— 对焦要的是"缓缓推进"，幅度太大就变成猛推了。
    private static func focusScaleAmount(_ overlay: TextOverlay) -> Double {
        0.30 * overlay.animation.intensity
    }

    private static func breatheAmplitude(_ intensity: Double) -> Double {
        0.035 * intensity
    }

    /// 逐字效果里，单个字形自己的过渡占整段时长的比例。
    ///
    /// 0.45：最后一个字形在 55% 处起步、100% 处到位。给得太大就退化成"整块一起
    /// 动"，太小则每个字都是瞬间出现，两头都没有错峰的味道。
    private static let glyphWindow = 0.45

    // MARK: - 各效果

    private static func apply(
        _ kind: TextAnimationKind, reveal: Double, phase: Phase,
        overlay: TextOverlay, canvas: CGSize, into state: inout TextAnimationState
    ) {
        let r = min(max(reveal, 0), 1)
        switch kind {
        case .none:
            return

        case .fade:
            state.opacity = eased(r, phase: phase)

        case .rise:
            let e = eased(r, phase: phase)
            state.opacity = e
            state.offsetY = (1 - e) * riseAmplitude(overlay, canvas: canvas) * phase.riseSign

        case .pop:
            let start = popStartScale(overlay)
            // 入场用带回弹的 back（冲过头一点再退回来），出场用 easeIn 直接收走
            // —— 出场再弹一下像没关紧的弹簧。
            let curve = phase == .entrance ? TextEasing.easeOutBack(r) : TextEasing.easeInCubic(r)
            state.opacity = TextEasing.easeOutCubic(r)
            state.scale = start + (1 - start) * curve

        case .typewriter:
            state.perGlyph = TextAnimationState.PerGlyph(
                progress: glyphProgress(overlay, reveal: r, eased: false),
                riseY: 0,
                hardCut: true
            )

        case .cascade:
            state.perGlyph = TextAnimationState.PerGlyph(
                progress: glyphProgress(overlay, reveal: r, eased: true),
                riseY: riseAmplitude(overlay, canvas: canvas) * phase.riseSign,
                hardCut: false
            )

        case .blur:
            let e = eased(r, phase: phase)
            state.opacity = e
            state.blur = (1 - e) * blurAmplitude(overlay, canvas: canvas)

        case .focus:
            // **不用 `eased`**：入场那条是 easeOutCubic（先快后慢），它把动作
            // 压在前三分之一，观感是"弹进来然后停住"—— 正好是对焦不要的。
            // 这里用两头略缓、中间匀速的曲线，全程都在缓缓推进。
            let e = TextEasing.easeInOutSine(r)
            let floor = min(max(overlay.animation.focusStartOpacity, 0), 1)
            state.opacity = floor + (1 - floor) * e
            state.blur = (1 - e) * blurAmplitude(overlay, canvas: canvas)
            // 入场缩着进来收到 1；出场**继续放大**（镜头一直往前推，最后失焦），
            // 与 `rise` 的「从下面来、往上走」是同一个思路：连贯的一段运动。
            let amount = focusScaleAmount(overlay)
            state.scale = phase == .entrance
                ? 1 - amount * (1 - e)
                : 1 + amount * (1 - e)

        case .wipe:
            // 线性：擦除的"进度"本来就是几何量，再加缓动会让扫过的速度忽快忽慢。
            state.wipe = TextEasing.linear(r)

        case .strokeDraw:
            // 描边先扫出来（略快），填充过了三分之一再化进来。
            state.strokeDraw = TextAnimationState.StrokeDraw(
                strokeWipe: min(1, r * 1.4),
                fillOpacity: TextEasing.easeOutCubic(max(0, (r - 0.35) / 0.65))
            )
        }
    }

    /// 入场先快后慢，出场先慢后快 —— 东西该"被抽走"，不是"慢慢停住"。
    private static func eased(_ r: Double, phase: Phase) -> Double {
        phase == .entrance ? TextEasing.easeOutCubic(r) : TextEasing.easeInCubic(r)
    }

    /// 每个字符的进度：第 i 个在 `i/(n-1) * (1 - glyphWindow)` 处起步，
    /// 各自用 `glyphWindow` 那么长走完，于是最后一个正好在 r=1 到位。
    private static func glyphProgress(
        _ overlay: TextOverlay, reveal: Double, eased: Bool
    ) -> [Double] {
        let count = overlay.text.count
        guard count > 0 else { return [] }
        guard count > 1 else { return [eased ? TextEasing.easeOutCubic(reveal) : reveal] }
        let step = (1 - glyphWindow) / Double(count - 1)
        return (0..<count).map { index in
            let start = Double(index) * step
            let raw = (reveal - start) / glyphWindow
            let clamped = min(max(raw, 0), 1)
            return eased ? TextEasing.easeOutCubic(clamped) : clamped
        }
    }

    private static func applyEmphasis(
        _ kind: TextEmphasisKind, local: Double, intensity: Double,
        frameRate: ProjectFrameRate, into state: inout TextAnimationState
    ) {
        switch kind {
        case .none:
            return
        case .breathe:
            // 整段期间一直在走，与入场/出场**相乘**叠加：入场缩放到位的同时
            // 呼吸已经在起作用，两者不会互相打架。
            let phase = local / TextAnimation.breathePeriod(frameRate: frameRate)
            let wave = sin(phase * 2 * .pi)
            state.scale *= 1 + breatheAmplitude(intensity) * wave
        }
    }

    // MARK: - 包络
    //
    // 逐帧导出时**每一帧都按同一个框渲**，overlay 的 x/y 才能全程固定。
    // 所以框要按整段动画的**极值**算，不是按某一帧。

    /// 这段动画会把画面撑到多大：额外的四周外扩（画布像素）和最大缩放。
    static func envelopeAllowance(
        for overlay: TextOverlay, canvas: CGSize
    ) -> (inset: Double, scale: Double) {
        let animation = overlay.animation
        guard !animation.isEmpty else { return (0, 1) }

        var inset = 0.0
        var scale = 1.0
        let kinds = [animation.entrance, animation.exit]

        if kinds.contains(.rise) || kinds.contains(.cascade) {
            inset = max(inset, riseAmplitude(overlay, canvas: canvas))
        }
        if kinds.contains(.blur) || kinds.contains(.focus) {
            // 模糊要留够：CG 的 blur 不是严格的高斯半径，1.5 倍是经验余量，
            // 留少了影子会被位图边缘切掉一条直边（非常显眼）。
            inset = max(inset, blurAmplitude(overlay, canvas: canvas) * 1.5)
        }
        if kinds.contains(.pop) {
            // easeOutBack 会冲过 1（最多约 1.1），包络要按冲过头之后算。
            scale = max(scale, 1.1)
        }
        // 对焦**只有出场会超过 1**（入场是缩着进来的），所以只看出场那一侧 ——
        // 一律按放大算的话，只做入场对焦的文字会白白多出一圈空位图。
        if animation.exit == .focus {
            scale = max(scale, 1 + focusScaleAmount(overlay))
        }
        if animation.emphasis == .breathe {
            scale = max(scale, 1 + breatheAmplitude(animation.intensity))
        }
        return (inset, scale)
    }
}
