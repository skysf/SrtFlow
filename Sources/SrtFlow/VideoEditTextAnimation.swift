import Foundation
import SrtFlowCore

// MARK: - 文字动画的模型
//
// 三个槽：**入场、出场、强调**。入场和出场各自选一种效果 + 一个时长，
// 强调是整段期间一直循环的那种。再加一个全局的**强度**。
//
// 为什么不把每种效果的参数都摊开：质感来自缓动曲线、错峰间隔、回弹幅度这些
// 用户调不出来的东西，摊开只会让人调出难看的结果还以为是功能不行。
//
// ## 动画是相对基准位置的偏移
//
// 画面上拖出来的位置永远是**动画播完的落点**。动画只在这个基准上叠偏移，
// 不改 `centerX/centerY`。否则动画一跑选中框就跟着飞，根本拖不住。
// 这条是 text-overlays.md 里写死的不变量。
//
// ## 时长夹紧与声音/画面渐变共用一份
//
// 「入场 0.6s + 出场 0.6s 撞上只有 0.8s 的文字」和「音频渐入渐出超过段长」
// 是同一个问题，所以用同一个 `FadeWindow.clamped`：各自不超过段长，两者之和
// 超了就按比例同时收。存的是**用户的意图**，夹紧在读侧做 —— 段被拉长之后
// 动画应当跟着恢复，而不是写入那一刻就被当时的时长永久截短。

/// 入场 / 出场的效果。成对使用：出场是入场的反向。
enum TextAnimationKind: String, CaseIterable, Identifiable, Hashable, Sendable {
    case none
    /// 淡入淡出。
    case fade
    /// 上浮：入场从下方浮上来，出场继续向上移出（连贯的一段运动，
    /// 比"原路退回去"更像设计过的）。
    case rise
    /// 弹性缩放：缩着进来，冲过头一点再回弹到位。
    case pop
    /// 打字机：逐字出现，没有位移也没有淡变。
    case typewriter
    /// 逐字错峰上浮：每个字差一点点依次浮起并化入。**质感主要来自这个**。
    case cascade
    /// 模糊解析：从模糊 + 透明收敛到清晰。**不带缩放**。
    case blur
    /// 对焦：一边缓缓放大、一边从模糊收紧到清晰。两件事同时发生。
    ///
    /// 与 `pop` 的区别是**没有回弹**、曲线接近匀速 —— `pop` 把动作压在前三分之一，
    /// 观感是"弹进来然后停住"；对焦要的是全程缓缓推进，像电影里的慢推镜头。
    /// 与 `blur` 的区别是它同时缩放。
    case focus
    /// 遮罩擦除：从一侧扫出来。
    case wipe
    /// 描边生长：描边先扫出来，填充随后化进来。
    case strokeDraw

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .fade: return "Fade"
        case .rise: return "Rise"
        case .pop: return "Pop"
        case .typewriter: return "Typewriter"
        case .cascade: return "Cascade"
        case .blur: return "Blur"
        case .focus: return "Focus"
        case .wipe: return "Wipe"
        case .strokeDraw: return "Draw on"
        }
    }

    /// 只有描边存在时才有意义的效果 —— 界面上要当场说清楚，
    /// 不然用户选了「描边生长」却什么都没发生，会以为坏了。
    var needsStroke: Bool { self == .strokeDraw }

    /// 逐字效果：渲染要拆成一个字形一次绘制（整块批量画不出错峰）。
    var isPerGlyph: Bool { self == .typewriter || self == .cascade }
}

/// 整段期间一直循环的强调效果。
enum TextEmphasisKind: String, CaseIterable, Identifiable, Hashable, Sendable {
    case none
    /// 呼吸缩放：极轻微的一张一弛。幅度必须小到"看不出在动、但感觉是活的"。
    case breathe

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .breathe: return "Breathe"
        }
    }
}

struct TextAnimation: Hashable, Sendable {
    var entrance: TextAnimationKind
    var exit: TextAnimationKind
    /// 时间线秒。0 = 该侧不做动画。
    var entranceDuration: Double
    var exitDuration: Double
    var emphasis: TextEmphasisKind
    /// 幅度总控 0…1：位移多远、缩多小、糊多厉害，统一按它缩放。
    var intensity: Double
    /// 对焦效果起手（和收尾）时的不透明度。**只对 `.focus` 有意义。**
    ///
    /// 1 = 完全不淡入，一上来就是一片满不透明的模糊色块再收紧成字 ——
    /// 最像相机对焦，但起手那一团糊斑挺显眼。
    /// 0 = 从全透明淡进来，衔接最柔和，但就少了对焦那个味道。
    /// 默认 0.35：起手不是实色斑，收尾又保留对焦感。
    ///
    /// 入场和出场**对称**用同一个值：出场结束时停在这个不透明度上再切走。
    /// 想要干净地消失就调到 0。
    ///
    /// **默认值写在这里**（不是写在 `.default` 里）：合成的按成员构造器会跟着
    /// 有默认参数，于是不关心对焦的调用点一个字都不用改，而这个数也只出现一次。
    var focusStartOpacity: Double = 0.35

    static let `default` = TextAnimation(
        entrance: .none, exit: .none,
        entranceDuration: 0.6, exitDuration: 0.6,
        emphasis: .none, intensity: 0.6
    )

    static let durationRange = 0.1...5.0
    static let intensityRange = 0.0...1.0
    static let focusStartOpacityRange = 0.0...1.0

    /// 这份动画里用到对焦了吗（界面据此决定要不要露出那个滑块）。
    var usesFocus: Bool { entrance == .focus || exit == .focus }
    /// 呼吸一个来回的目标秒数。做成常量而不是参数：调快了像抽搐，调慢了看不
    /// 出来，中间那一小段才是对的，没必要让用户去找。
    private static let breathePeriodTarget = 3.4

    /// 实际周期：按帧率**取整到整数帧**。
    ///
    /// 导出时循环段只渲一个周期，交给 ffmpeg 的 `loop` 滤镜铺满整段
    ///（否则 10 分钟的呼吸文字要逐帧渲成几个 GB）。周期不是整数帧的话，
    /// 循环接缝处相位会错开，看起来像卡了一下。
    static func breathePeriod(frameRate: ProjectFrameRate) -> Double {
        let fps = Double(max(1, frameRate.fps))
        return max(1, (breathePeriodTarget * fps).rounded()) / fps
    }

    var isEmpty: Bool {
        entrance == .none && exit == .none && emphasis == .none
    }

    /// 这一段真正生效的入/出场时长（夹紧之后）。
    ///
    /// 与声音、画面渐变共用 `FadeWindow.clamped`：谁先夹、超长怎么按比例收、
    /// 多小算没设，三处必须逐字相同，抄第二份一定会在边界条件上分叉。
    func window(span: Double) -> FadeWindow {
        FadeWindow.clamped(
            fadeIn: entrance == .none ? 0 : entranceDuration,
            fadeOut: exit == .none ? 0 : exitDuration,
            span: span
        )
    }

    mutating func clampToValidRange() {
        entranceDuration = min(max(entranceDuration, TextAnimation.durationRange.lowerBound),
                               TextAnimation.durationRange.upperBound)
        exitDuration = min(max(exitDuration, TextAnimation.durationRange.lowerBound),
                           TextAnimation.durationRange.upperBound)
        intensity = min(max(intensity, TextAnimation.intensityRange.lowerBound),
                        TextAnimation.intensityRange.upperBound)
        focusStartOpacity = min(max(focusStartOpacity, TextAnimation.focusStartOpacityRange.lowerBound),
                                TextAnimation.focusStartOpacityRange.upperBound)
    }
}

// MARK: - 存盘

extension TextAnimationKind: LenientCodableEnum {
    static var decodingFallback: TextAnimationKind { .none }
}

extension TextEmphasisKind: LenientCodableEnum {
    static var decodingFallback: TextEmphasisKind { .none }
}

extension TextAnimation: Codable {
    private enum CodingKeys: String, CodingKey {
        case entrance, exit, entranceDuration, exitDuration, emphasis, intensity
        case focusStartOpacity
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = TextAnimation.default
        self.init(
            entrance: try c.decodeIfPresent(TextAnimationKind.self, forKey: .entrance) ?? .none,
            exit: try c.decodeIfPresent(TextAnimationKind.self, forKey: .exit) ?? .none,
            entranceDuration: try c.decodeIfPresent(Double.self, forKey: .entranceDuration)
                ?? fallback.entranceDuration,
            exitDuration: try c.decodeIfPresent(Double.self, forKey: .exitDuration)
                ?? fallback.exitDuration,
            emphasis: try c.decodeIfPresent(TextEmphasisKind.self, forKey: .emphasis) ?? .none,
            intensity: try c.decodeIfPresent(Double.self, forKey: .intensity) ?? fallback.intensity,
            focusStartOpacity: try c.decodeIfPresent(Double.self, forKey: .focusStartOpacity)
                ?? fallback.focusStartOpacity
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(entrance, forKey: .entrance)
        try c.encode(exit, forKey: .exit)
        try c.encode(entranceDuration, forKey: .entranceDuration)
        try c.encode(exitDuration, forKey: .exitDuration)
        try c.encode(emphasis, forKey: .emphasis)
        try c.encode(intensity, forKey: .intensity)
        // 只在真用了对焦时才落这个键：没用到的话它是个无意义的数字，
        // 写进去会让「按需抬版本」那条判据变得说不清。
        if usesFocus { try c.encode(focusStartOpacity, forKey: .focusStartOpacity) }
    }
}
