import Foundation

/// 一段素材头尾各渐变多久（**时间线秒**，变速之后）。
///
/// 声音（`EditClip.audioFades`）和画面（`EditClip.videoFades`）共用这一份结构和
/// **同一套夹紧规则** —— 两边的产品语义逐字相同（「这一段的开头/结尾渐变多久」），
/// 抄成两份就一定会在边界条件上分叉（谁先夹、超长怎么收、多小算没设）。
/// 领域相关的部分各自放在 `VideoEditAudioFade.swift`（`afade` 段、音量斜坡）和
/// `VideoEditVideoFade.swift`（`fade=alpha`、透明度斜坡）里。
///
/// 长期约束见 docs/architecture/audio-fades.md 与 docs/architecture/video-fades.md。
struct FadeWindow: Equatable, Sendable {
    /// 时间线秒；0 表示这一边不做渐变。
    var fadeIn: Double
    var fadeOut: Double

    static let none = FadeWindow(fadeIn: 0, fadeOut: 0)

    var isEmpty: Bool { fadeIn <= 0 && fadeOut <= 0 }

    /// 转场仲裁：接缝上转场自己就在做交叉淡变（预览的双轨斜坡 / 导出的
    /// `xfade` + `acrossfade`），那条边整个归转场管，用户设的渐变在这一边不生效。
    ///
    /// 为什么不叠加：两段衰减相乘会在接缝处压出一个明显的坑 —— 声音断一下、
    /// 画面暗一块。为什么不取较长者：那样用户设的值会被静默改写，而转场时长
    /// 本来就是用户另外调过的。
    func suppressing(fadeIn suppressIn: Bool, fadeOut suppressOut: Bool) -> FadeWindow {
        FadeWindow(
            fadeIn: suppressIn ? 0 : fadeIn,
            fadeOut: suppressOut ? 0 : fadeOut
        )
    }

    /// 存下来的两个时长 → 这一段实际生效的渐变窗口。
    ///
    /// 三重收口，缺一不可：
    /// 1. 非有限值和负数归零 —— 数值框和工程文件都可能喂进 NaN。
    /// 2. 各自不超过段长。
    /// 3. 两者之和超过段长时**按比例同时收**到正好铺满，不留恒定的中段。
    ///    只夹单边的话，「渐入 3s + 渐出 3s」放在 4s 的段上会算出负长度的中段：
    ///    `setVolumeRamp` / `setOpacityRamp` 收到反向 timeRange 直接不生效
    ///    （整段变回原值），ffmpeg 那边则是两条 fade 重叠、尾部被提前拉到 0。
    static func clamped(fadeIn rawIn: Double, fadeOut rawOut: Double, span: Double) -> FadeWindow {
        guard span > 0 else { return .none }
        var fadeIn = rawIn.isFinite ? max(0, rawIn) : 0
        var fadeOut = rawOut.isFinite ? max(0, rawOut) : 0
        fadeIn = min(fadeIn, span)
        fadeOut = min(fadeOut, span)
        let total = fadeIn + fadeOut
        if total > span {
            let scale = span / total
            fadeIn *= scale
            fadeOut *= scale
        }
        // 毫秒以下的渐变看不见也听不出来，却会在导出滤镜里留下 d=0.000 这种参数。
        return FadeWindow(
            fadeIn: fadeIn < 0.001 ? 0 : fadeIn,
            fadeOut: fadeOut < 0.001 ? 0 : fadeOut
        )
    }
}

/// 渐变的哪一头。Inspector 的数值框和 Project 的写入方法共用它，
/// 省得为「进」「出」各抄一份夹紧逻辑。声音和画面共用。
enum FadeEdge: Hashable, Sendable {
    case fadeIn
    case fadeOut
}
