import Foundation

/// 声音的渐入渐出（fade in / fade out）。
///
/// 存的是 `EditClip.fadeInDuration` / `fadeOutDuration`，单位是**时间线秒**
/// （变速之后）—— 用户在时间线上看到的就是这个长度，变速不该让他重算。
///
/// 预览（`AVMutableAudioMixInputParameters.setVolumeRamp`）和导出
/// （ffmpeg `afade`）都必须从**这里**取生效值，不许各自夹紧各自的：两边分叉
/// 就是「预览听着对、成片不对」。曲线两边都是线性（`afade` 默认 `tri` 即线性），
/// 所以同一组时长在两条管线上逐样本一致。
///
/// 长期约束见 docs/architecture/audio-fades.md。

/// 渐变的哪一头。Inspector 的两个数值框和 Project 的写入方法共用它，
/// 省得为「进」「出」各抄一份夹紧逻辑。
enum AudioFadeEdge: Hashable, Sendable {
    case fadeIn
    case fadeOut
}

/// 音量的 dB 表示。
///
/// **存下来的一直是线性幅度**（`EditClip.volume`，0…2，1.0 = 原样）——
/// 工程文件里的语义不变，dB 只是界面上的换算。这样老工程照读，格式也不用升版。
///
/// 为什么界面要用 dB：线性幅度对听感极不均匀。0.1 和 0.2 听上去差一倍，
/// 1.0 和 1.1 几乎听不出来，可它们在滑杆上占一样宽。dB 是等比刻度，
/// 拖起来每一段的手感才一致。
enum AudioGain {
    /// 滑杆的下限。到底就是静音（线性 0，dB 上是 −∞）。
    static let minimumDB = -60.0
    /// 线性幅度的上限，跟 `VideoEditProject.setVolume` 的夹紧保持一致。
    static let maximumLinear = 2.0
    /// 上限**从线性上限算出来**（≈ +6.02 dB），不写成整数 6.0 —— 写死 6.0 的话
    /// 线性 2.0 换成 dB 再换回来会掉到 1.995，用户把滑杆推到顶再松手音量会
    /// 自己往回缩一点点。
    static let maximumDB = 20 * log10(maximumLinear)

    /// 线性幅度 → dB。0（静音）返回下限，界面上显示成 −∞。
    static func decibels(fromLinear linear: Double) -> Double {
        guard linear.isFinite, linear > 0 else { return minimumDB }
        return min(max(20 * log10(linear), minimumDB), maximumDB)
    }

    /// dB → 线性幅度。到达下限就是真静音（0），不是 0.001。
    static func linear(fromDecibels decibels: Double) -> Double {
        guard decibels.isFinite else { return 1 }
        if decibels <= minimumDB { return 0 }
        return min(pow(10, min(decibels, maximumDB) / 20), maximumLinear)
    }

    /// 数值框/滑杆上显示的文字。−60 dB 是「关到底」，写 −∞ 比写 −60.0 诚实。
    static func label(forLinear linear: Double) -> String {
        let value = decibels(fromLinear: linear)
        if value <= minimumDB { return "−∞ dB" }
        return String(format: "%.1f dB", value).replacingOccurrences(of: "-", with: "−")
    }
}

struct AudioFadeWindow: Equatable, Sendable {
    /// 时间线秒；0 表示这一边不做渐变。
    var fadeIn: Double
    var fadeOut: Double

    static let none = AudioFadeWindow(fadeIn: 0, fadeOut: 0)

    var isEmpty: Bool { fadeIn <= 0 && fadeOut <= 0 }

    /// 转场仲裁：主轨接缝上转场自己就在做交叉淡变（预览的双轨斜坡 /
    /// 导出的 `acrossfade`），那条边整个归转场管，用户设的渐变在这一边不生效。
    ///
    /// 为什么不叠加：两段衰减相乘会在接缝处把音量压出一个明显的坑，
    /// 听感上就是「转场的地方声音断了一下」。为什么不取较长者：那样用户
    /// 设的值会被静默改写，而转场时长本来就是用户另外调过的。
    func suppressing(fadeIn suppressIn: Bool, fadeOut suppressOut: Bool) -> AudioFadeWindow {
        AudioFadeWindow(
            fadeIn: suppressIn ? 0 : fadeIn,
            fadeOut: suppressOut ? 0 : fadeOut
        )
    }

    /// 主轨某一段在**预览**里最终生效的音量斜坡。
    ///
    /// 预览没有 `acrossfade` 这种东西，转场的交叉淡变**就是**靠这里的斜坡实现的，
    /// 所以有转场的边要换成转场时长本身。
    ///
    /// - Parameters:
    ///   - transitionBefore: 与**前**一段的转场重叠时长（0 = 这条边没有转场）
    ///   - transitionAfter: 与**后**一段的转场重叠时长（0 = 这条边没有转场）
    static func previewMainTrack(
        clip: EditClip, transitionBefore: Double, transitionAfter: Double
    ) -> AudioFadeWindow {
        let user = clip.audioFades
            .suppressing(fadeIn: transitionBefore > 0, fadeOut: transitionAfter > 0)
        return AudioFadeWindow(
            fadeIn: transitionBefore > 0 ? transitionBefore : user.fadeIn,
            fadeOut: transitionAfter > 0 ? transitionAfter : user.fadeOut
        )
    }

    /// 主轨某一段在**导出**里由段内滤镜负责的音量斜坡。
    ///
    /// 和预览的差别只有一处，但很容易写错：导出的转场交叉淡变是在**段与段之间**
    /// 由 `acrossfade` 做的，不在段内的滤镜链里。所以这里有转场的边只做「抑制」，
    /// **不能**把转场时长再加进段内的 `afade` —— 加了就是转场处衰减两遍。
    static func exportMainTrack(
        clip: EditClip, hasTransitionBefore: Bool, hasTransitionAfter: Bool
    ) -> AudioFadeWindow {
        clip.audioFades.suppressing(fadeIn: hasTransitionBefore, fadeOut: hasTransitionAfter)
    }

    /// 导出滤镜链里要插的 `afade`（`type` 是 `in` / `out`，起点和时长都是秒）。
    ///
    /// - Parameter timelineDuration: 这段在**时间线上**的长度，也就是变速之后的
    ///   长度。`afade` 的 `st` 读的是它在链上看到的时间轴，而链上 `atempo`
    ///   已经跑过了 —— 拿源长度算淡出起点，变速的段会淡错地方（2x 的段会在
    ///   一半处就开始淡出）。
    ///
    /// 曲线不显式写：`afade` 默认 `curve=tri` 就是线性，与预览
    /// `setVolumeRamp` 的线性斜坡逐样本一致。写死别的曲线就会两边分叉。
    func afadeSegments(timelineDuration: Double) -> [(type: String, start: Double, duration: Double)] {
        var segments: [(type: String, start: Double, duration: Double)] = []
        if fadeIn > 0 {
            segments.append((type: "in", start: 0, duration: fadeIn))
        }
        if fadeOut > 0 {
            segments.append((
                type: "out",
                start: max(0, timelineDuration - fadeOut),
                duration: fadeOut
            ))
        }
        return segments
    }
}

extension EditClip {
    /// 这一段实际生效的渐入/渐出（时间线秒）。
    ///
    /// 三重收口，缺一不可：
    /// 1. 非有限值和负数归零 —— 数值框和工程文件都可能喂进 NaN。
    /// 2. 各自不超过段长。
    /// 3. 两者之和超过段长时**按比例同时收**到正好铺满，不留恒定音量的中段。
    ///    只夹单边的话，「渐入 3s + 渐出 3s」放在 4s 的段上会算出负长度的
    ///    中段：`setVolumeRamp` 收到反向 timeRange 直接不生效（整段变成原音量），
    ///    ffmpeg 那边则是两条 `afade` 重叠、尾部被提前拉到 0。
    var audioFades: AudioFadeWindow {
        let span = timelineDuration
        guard span > 0 else { return .none }
        var fadeIn = fadeInDuration.isFinite ? max(0, fadeInDuration) : 0
        var fadeOut = fadeOutDuration.isFinite ? max(0, fadeOutDuration) : 0
        fadeIn = min(fadeIn, span)
        fadeOut = min(fadeOut, span)
        let total = fadeIn + fadeOut
        if total > span {
            let scale = span / total
            fadeIn *= scale
            fadeOut *= scale
        }
        // 毫秒以下的渐变听不出来，却会在导出滤镜里留下 d=0.000 这种参数。
        return AudioFadeWindow(
            fadeIn: fadeIn < 0.001 ? 0 : fadeIn,
            fadeOut: fadeOut < 0.001 ? 0 : fadeOut
        )
    }
}

extension TimelineState {
    /// 有任何一段设了渐变吗（工程格式 v9 的判据，看的是**存下来的值**，
    /// 不是夹紧后的生效值 —— 版本闸门问的是「旧版会丢掉什么数据」）。
    var hasAudioFades: Bool {
        allClips.contains { $0.fadeInDuration > 0 || $0.fadeOutDuration > 0 }
    }

    /// 两份状态**只差在音量/渐变**上吗。
    ///
    /// 这三个字段只进 audioMix，不改合成结构，所以改它们不必重建整条预览
    /// （重建会 `replaceCurrentItem`，画面必闪一下）。判据故意写成「把这几个
    /// 字段抹平之后两边完全相等」——**别去枚举「哪些字段算变了」**：
    /// 那种写法每加一个新字段就漏一次，而漏的方向是「本该重建却没重建」，
    /// 表现为改了东西预览不更新，比闪一下难查得多。
    func differsOnlyInAudioMix(from other: TimelineState) -> Bool {
        guard self != other else { return false }
        return audioMixNeutralized() == other.audioMixNeutralized()
    }

    /// 把所有段的音量/渐变抹成同一个值，只留「合成结构」那部分身份。
    private func audioMixNeutralized() -> TimelineState {
        var copy = self
        copy.mutateAllClips { clip in
            clip.volume = 1
            clip.fadeInDuration = 0
            clip.fadeOutDuration = 0
        }
        return copy
    }

    /// 对三类轨上的每一段就地改一遍。
    mutating func mutateAllClips(_ change: (inout EditClip) -> Void) {
        for index in mainClips.indices { change(&mainClips[index]) }
        for lane in overlayTracks.indices {
            for index in overlayTracks[lane].clips.indices { change(&overlayTracks[lane].clips[index]) }
        }
        for lane in audioTracks.indices {
            for index in audioTracks[lane].clips.indices { change(&audioTracks[lane].clips[index]) }
        }
    }
}

/// 预览合成建好之后，「哪些段的声音落在哪条合成音轨上」的记录。
///
/// 有了它就能在**不重建合成**的前提下只重算一遍 audioMix：改音量或渐变时
/// 直接把新的 mix 赋给正在播的 `AVPlayerItem`，画面完全不动。
///
/// 只对「合成结构不变」的改动有效 —— 判据是
/// `TimelineState.differsOnlyInAudioMix`。静音（Mute）**不在**其中：主轨和
/// 画中画的静音段压根不会被插进合成音轨，改它会改结构。
struct AudioMixPlan: Equatable, Sendable {
    /// 一条合成音轨上按插入顺序排下来的段。
    struct Lane: Equatable, Sendable {
        /// `CMPersistentTrackID`（就是 Int32），用它重建 input parameters。
        var trackID: Int32
        var clipIDs: [UUID]
        /// 主轨的声音要按转场仲裁算斜坡，画中画/音频轨不用。
        var isMainTrack: Bool
    }

    var lanes: [Lane] = []

    mutating func record(trackID: Int32, clipID: UUID, isMainTrack: Bool) {
        if let index = lanes.firstIndex(where: { $0.trackID == trackID }) {
            lanes[index].clipIDs.append(clipID)
        } else {
            lanes.append(Lane(trackID: trackID, clipIDs: [clipID], isMainTrack: isMainTrack))
        }
    }
}
