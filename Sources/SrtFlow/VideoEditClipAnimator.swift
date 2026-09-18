import CoreGraphics
import Foundation
import SrtFlowCore

// MARK: - 预设动画的求值：时刻 → 这一帧该怎么摆
//
// **只算不画**，而且**只用比例不用像素**：返回的位移是"素材框自身高/宽的几分之几"，
// 缩放是倍数。好处有两个 —— 求值器不需要知道画布、摆放、旋转这些几何，
// 自检可以直接逐帧调它比数值；同一份结果既能喂预览的 `setTransformRamp`，
// 也能喂预渲染（两者本来就是同一套合成代码）。
//
// ## 不需要像文字那样量化到帧
//
// 文字有两个渲染器（预览的 CoreGraphics 和导出的 PNG 序列）要逐点对齐，所以
// `TextAnimator.quantize` 把时刻钉到帧网格上。段这边只有一套：预览是
// AVFoundation 合成，导出的中间片也是**同一份合成代码**渲的，按构造一致。
//
// ## 入场和出场不会重叠
//
// 窗口走 `FadeWindow.clamped`（`ClipPreset.effective` 里收的口），它保证两者
// 之和不超过段长。所以求值是干净的三段式：入场 / 中间 / 出场。

/// 某一时刻这一段该怎么画。默认值就是"不动"。
struct ClipAnimationState: Equatable {
    /// 整层不透明度乘数。
    var opacity: Double = 1
    /// 位移，单位是**素材框自身的宽/高的比例**；y 向下为正（与 `ClipPlacement`
    /// 的画布坐标系一致：centerY 变大＝往下）。
    var offset: CGPoint = .zero
    /// 绕摆放框中心的等比缩放。
    var scale: Double = 1
    /// 横向擦除：露出素材框**左起**这么多比例。nil = 不擦。
    var reveal: Double?

    var isIdentity: Bool {
        opacity == 1 && offset == .zero && scale == 1 && reveal == nil
    }

    /// 把位移和缩放叠到一个摆放框上（绕框中心缩放，再按框自身尺寸平移）。
    func apply(to frame: CGRect) -> CGRect {
        guard offset != .zero || scale != 1 else { return frame }
        let width = frame.width * scale
        let height = frame.height * scale
        let centerX = frame.midX + offset.x * frame.width
        let centerY = frame.midY + offset.y * frame.height
        return CGRect(
            x: centerX - width / 2, y: centerY - height / 2,
            width: width, height: height
        )
    }
}

enum ClipAnimator {

    // MARK: 幅度
    //
    // 全部按**素材框自身**算，不按画布：同一套动画配在铺满画布的图和角落里的
    // 小 PNG 上，位移都应当各自成比例。
    //
    // 铺满画布的段用一套更小的幅度：满屏画面挪 16% 屏高是"甩进来"，而且位移
    // 越大、补偿放大就越狠（见 `covered`），5% 配 1.10 的补偿是实测舒服的档。

    private static func riseFraction(intensity: Double, coversCanvas: Bool) -> Double {
        (coversCanvas ? 0.05 : 0.16) * intensity
    }

    private static func popAmount(intensity: Double, coversCanvas: Bool) -> Double {
        (coversCanvas ? 0.18 : 0.35) * intensity
    }

    private static func zoomAmount(intensity: Double) -> Double {
        0.12 * intensity
    }

    /// 这一刻的动画状态。
    ///
    /// - Parameters:
    ///   - local: 距这一段开头的秒数（时间线秒）。
    ///   - span: 这一段的时间线长度。
    ///   - coversCanvas: 摆放框盖满画布了吗（`EditClip.placementCoversCanvas`）。
    ///     盖满时位移/缩放要做"不露边补偿"，见下。
    static func state(
        resolved: ResolvedClipPreset, local: Double, span: Double, coversCanvas: Bool
    ) -> ClipAnimationState {
        var state = ClipAnimationState()
        guard !resolved.isEmpty, span > 0 else { return state }

        let window = resolved.window
        if window.fadeIn > 0, local < window.fadeIn {
            apply(resolved.entrance, reveal: local / window.fadeIn, phase: .entrance,
                  intensity: resolved.intensity, coversCanvas: coversCanvas, into: &state)
        } else if window.fadeOut > 0, local > span - window.fadeOut {
            apply(resolved.exit, reveal: (span - local) / window.fadeOut, phase: .exit,
                  intensity: resolved.intensity, coversCanvas: coversCanvas, into: &state)
        }

        // 不露边（产品决策 2026-09-18 第 4 条）：盖满画布的段一旦往上浮或者缩小，
        // 边上就会露出底下那一层（主轨是黑场、上层轨是主轨画面）。按位移量补一点
        // 放大盖回去 —— 框往上挪 dy（框高的比例），下边要够到原位就得放大到
        // `1 + 2·dy`。末了再兜一道 `≥ 1`：回弹曲线尾巴那点越界（最多 ~2%）
        // 被夹掉，观感是"落到位停住"，而不是闪一帧黑边。
        if coversCanvas {
            let reach = 1 + 2 * max(abs(state.offset.x), abs(state.offset.y))
            state.scale = max(state.scale, reach)
        }
        return state
    }

    private enum Phase {
        case entrance
        case exit
        /// 上浮：入场从下方来（+），出场继续往上走（−）。**连贯的一段运动**，
        /// 比"原路退回去"更像设计过的（与文字同口径）。
        var riseSign: Double { self == .entrance ? 1 : -1 }
    }

    private static func apply(
        _ kind: ClipPresetKind, reveal: Double, phase: Phase,
        intensity: Double, coversCanvas: Bool, into state: inout ClipAnimationState
    ) {
        let r = min(max(reveal, 0), 1)
        switch kind {
        case .none:
            return

        case .fade:
            // **线性，不加缓动。** 这一条就是 v10 起的「画面渐变」：导出侧走
            // ffmpeg 的 `fade=…:alpha=1`（默认线性）、预览侧走 `setOpacityRamp`
            // （线性斜坡），两边逐帧一致靠的就是它。这里换成缓动曲线的话，
            // 同一个工程"只设了淡入"和"淡入 + 另一侧有位移动画"会走不同的路径、
            // 渲出不同的画面。
            state.opacity = r

        case .rise:
            let e = eased(r, phase: phase)
            state.opacity = e
            state.offset.y = (1 - e) * riseFraction(intensity: intensity, coversCanvas: coversCanvas)
                * phase.riseSign

        case .pop:
            // 盖满画布的段**反过来做**：从大落到位。从小弹进来会在四周露出一圈
            // 底下那层，而"弹"这件事本身就是缩放，没法靠补偿盖住。
            let amount = popAmount(intensity: intensity, coversCanvas: coversCanvas)
            let start = coversCanvas ? 1 + amount : 1 - amount
            // 入场用带回弹的 back（冲过头一点再退回来），出场用 easeIn 直接收走
            // —— 出场再弹一下像没关紧的弹簧。
            let curve = phase == .entrance ? TextEasing.easeOutBack(r) : TextEasing.easeInCubic(r)
            state.opacity = TextEasing.easeOutCubic(r)
            state.scale = start + (1 - start) * curve

        case .zoom:
            // 与 `rise` 同构，只是把"从下面来"换成"从大处来"：入场从 1+a 缓收到 1，
            // 出场继续往前推到 1+a（镜头一直在推，不倒车）。
            let e = eased(r, phase: phase)
            state.opacity = e
            state.scale = 1 + zoomAmount(intensity: intensity) * (1 - e)

        case .wipe:
            // 线性：擦除的"进度"本来就是几何量，再加缓动会让扫过的速度忽快忽慢。
            // 也**不带淡变** —— 擦除本身就是"露出来"。
            state.reveal = r
        }
    }

    /// 入场先快后慢，出场先慢后快 —— 东西该"被抽走"，不是"慢慢停住"。
    private static func eased(_ r: Double, phase: Phase) -> Double {
        phase == .entrance ? TextEasing.easeOutCubic(r) : TextEasing.easeInCubic(r)
    }

    // MARK: - 预览切片边界

    /// 单侧最多加密多少片。5 秒的入场在 60fps 工程上是 300 帧，全铺进指令表
    /// 不值得 —— 超过就按等距抽稀（曲线尾部本来就平，看不出来）。
    private static let maximumSamplesPerEdge = 120

    /// 这一段要在哪些时刻断片（时间线秒，含窗口端点，不含段首尾）。
    ///
    /// AVFoundation 的斜坡只会**线性**插值，所以片内必须是线性的：
    /// - `fade`：线性透明度 → 只要窗口端点；
    /// - `wipe`：reveal 线性、裁切矩形对 reveal 也线性 → 只要窗口端点；
    /// - `rise`/`pop`/`zoom`：带缓动曲线 → 窗口内按**工程帧**加密。
    static func sliceTimes(
        resolved: ResolvedClipPreset, clipStart: Double, span: Double, frameRate: ProjectFrameRate
    ) -> [Double] {
        guard !resolved.isEmpty, span > 0 else { return [] }
        var times: [Double] = []
        let step = 1.0 / Double(max(1, frameRate.fps))

        func addEdge(_ edge: FadeEdge) {
            let duration = resolved.duration(edge)
            guard duration > 0 else { return }
            // 窗口端点：入场是 [0, d]，出场是 [span-d, span]。
            let start = edge == .fadeIn ? 0 : span - duration
            times.append(clipStart + start)
            times.append(clipStart + start + duration)
            guard resolved.kind(edge).needsDenseSampling else { return }
            let count = min(maximumSamplesPerEdge, max(1, Int((duration / step).rounded(.up))))
            for index in 1..<max(1, count) {
                times.append(clipStart + start + duration * Double(index) / Double(count))
            }
        }
        addEdge(.fadeIn)
        addEdge(.fadeOut)
        return times
    }
}

extension ClipPresetKind {
    /// 曲线是非线性的，斜坡重建不了 —— 预览切片要在窗口内按帧加密。
    var needsDenseSampling: Bool {
        switch self {
        case .none, .fade, .wipe: return false
        case .rise, .pop, .zoom: return true
        }
    }
}

extension EditClip {
    /// 这一刻的预设动画状态。`resolved` 由调用方按转场上下文仲裁好
    /// （`ClipPreset.effective`）—— 求值器不认识时间线，也就管不了转场。
    func presetState(
        resolved: ResolvedClipPreset, atTimeline time: Double, canvas: CGSize
    ) -> ClipAnimationState {
        ClipAnimator.state(
            resolved: resolved,
            local: min(max(time - timelineStart, 0), timelineDuration),
            span: timelineDuration,
            coversCanvas: placementCoversCanvas(canvas: canvas)
        )
    }
}
