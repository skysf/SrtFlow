import Foundation

/// 画面的渐入渐出（fade in / fade out）—— **单段**的头尾渐变，不是接缝上的转场。
///
/// 存的是 `EditClip.videoFadeInDuration` / `videoFadeOutDuration`，单位是
/// **时间线秒**（变速之后），夹紧规则与声音共用 `FadeWindow.clamped`。
///
/// ## 渐变到什么
///
/// 这里做的一律是**整层 alpha 的线性斜坡**，不是「淡到黑」。渐变露出来的是
/// 这一段**底下那一层**：
///
/// - 主轨的段：底下是黑底（预览的 `BlackBaseVideoFactory` / 导出的
///   `color=black` 画布），所以看起来就是淡入淡出黑场；
/// - 上层视频轨的段：底下是主轨画面，所以是从主轨画面里化进来、再化回去。
///
/// 两种观感来自同一个滤镜、同一条斜坡，差别只在垫在下面的是什么 —— 正因如此
/// 预览和导出才不用各写一套。**别改成显式淡向黑色**：上层轨那样会把主轨闪黑。
///
/// ## 两条管线同账
///
/// | 管线 | 落点 |
/// | --- | --- |
/// | 预览（AVFoundation） | `PlacedClip.fadeIn/fadeOut` → layer instruction 的 `setOpacityRamp`（转场用的是同一套斜坡机制） |
/// | 导出（ffmpeg） | `VideoFade.filterSteps` → `fade=t=…:alpha=1`，接在变换链末尾 |
///
/// `fade=…:alpha=1` 是**乘**在已有 alpha 上的（实测：`aa=0.5` 的段淡入中点
/// alpha=64 而不是 128），与预览「斜坡整体乘 clip.opacity」同构。半透明的段
/// 渐变到自己的不透明度为止，两边逐帧一致。
enum VideoFade {
    /// 这一段最终生效的画面渐变。
    ///
    /// 只有一个口径（声音那边有 preview/export 两个）：画面转场的交叉淡变在
    /// 预览和导出里都**不经过**这条斜坡 —— 预览由 CompositionBuilder 的接缝
    /// 分派另行挂 `fadeIn/fadeOut`（还有推移/擦除两族根本不是淡变），导出由
    /// 段与段之间的 `xfade` 做。所以这里对有转场的边只做「抑制」，两条管线
    /// 拿到的是同一个值。
    static func effective(
        clip: EditClip, hasTransitionBefore: Bool, hasTransitionAfter: Bool
    ) -> FadeWindow {
        clip.videoFades.suppressing(fadeIn: hasTransitionBefore, fadeOut: hasTransitionAfter)
    }

    /// 导出滤镜链里要插的 `fade` 段（自带前导逗号；没渐变时是空串）。
    ///
    /// 必须接在变换链的**最末尾**：`st` 读的是链上的当前时间轴，而链上
    /// `setpts=(PTS-STARTPTS)/speed` 和 `fps` 都已经跑过，此刻 t=0 正是这一段
    /// 在时间线上的起点、总长正是 `timelineDuration`。拿源长度算淡出起点的话，
    /// 变速的段会淡错地方（2x 的段会在一半处就开始淡出）。
    ///
    /// 曲线不显式写：`fade` 默认就是线性，与预览 `setOpacityRamp` 的线性斜坡
    /// 逐帧一致。写死别的曲线就会两边分叉。
    static func filterSteps(_ window: FadeWindow, timelineDuration: Double) -> String {
        var steps: [String] = []
        if window.fadeIn > 0 {
            steps.append("fade=t=in:st=0:d=\(format(window.fadeIn)):alpha=1")
        }
        if window.fadeOut > 0 {
            let start = max(0, timelineDuration - window.fadeOut)
            steps.append("fade=t=out:st=\(format(start)):d=\(format(window.fadeOut)):alpha=1")
        }
        guard !steps.isEmpty else { return "" }
        return "," + steps.joined(separator: ",")
    }

    private static func format(_ value: Double) -> String {
        let rounded = (value * 1000).rounded() / 1000
        if rounded.truncatingRemainder(dividingBy: 1) == 0 { return String(Int(rounded)) }
        return String(format: "%g", rounded)
    }
}

extension EditClip {
    /// 这一段实际生效的画面渐入/渐出（时间线秒）。夹紧规则见 `FadeWindow.clamped`
    /// —— 与声音渐变**同一份**，两边不许各夹各的。
    var videoFades: FadeWindow {
        FadeWindow.clamped(
            fadeIn: videoFadeInDuration, fadeOut: videoFadeOutDuration, span: timelineDuration
        )
    }

    /// 画面渐变会让这一段在头尾变成半透明 —— 预览要不要垫黑底、导出要不要走
    /// rgba 链都看它。判据用**存下来的值**经夹紧后的结果，跟真正生效的一致。
    var hasVideoFade: Bool { !videoFades.isEmpty }
}

extension TimelineState {
    /// 有任何一段设了画面渐变吗（工程格式 v10 的判据，看的是**存下来的值**，
    /// 不是夹紧后的生效值 —— 版本闸门问的是「旧版会丢掉什么数据」）。
    var hasVideoFades: Bool {
        allClips.contains { $0.videoFadeInDuration > 0 || $0.videoFadeOutDuration > 0 }
    }
}
