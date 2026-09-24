import Foundation

/// 声音的渐入渐出（fade in / fade out）。
///
/// 存的是 `EditClip.fadeInDuration` / `fadeOutDuration`，单位是**时间线秒**
/// （变速之后）—— 用户在时间线上看到的就是这个长度，变速不该让他重算。
///
/// 预览的音量斜坡（`AVMutableAudioMixInputParameters.setVolumeRamp`）从**这里**取生效值，
/// 不许在调用点另夹一份。成片的声音自 2026-09-24 起就是预览这份混音离线读出来的
/// （ExportAudioMixdown），不再有 ffmpeg 的 `afade` 那一份 —— 两条管线只剩一条。
///
/// 长期约束见 docs/architecture/audio-fades.md。

/// 渐变的哪一头。声音和画面同一份（`FadeEdge`，见 VideoEditFadeWindow.swift）——
/// 「进」「出」的夹紧逻辑没有任何领域差别，抄第二份只会分叉。
typealias AudioFadeEdge = FadeEdge

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

    /// 线性幅度的合法区间 [0, 2]；NaN / inf 回 1（「没动过」），负数回 0。
    /// 读盘和推子写入共用（音量曲线、轨道推子、总推子），别在调用点各夹一份。
    static func clampedLinear(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return min(max(value, 0), maximumLinear)
    }

    /// dB 夹进 [−60, +6.02]；NaN 回 0 dB。
    static func clampedDecibels(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, minimumDB), maximumDB)
    }

    /// dB 在「dB 线性」刻度上的位置（0 = −∞，1 = +6.02）。检查器滑杆、块上的音量线、
    /// 轨道头推子都是这一个刻度 —— 三处各算一份的话，同一个 −6 dB 会画在三个地方。
    static func scaleFraction(forDecibels decibels: Double) -> Double {
        (clampedDecibels(decibels) - minimumDB) / (maximumDB - minimumDB)
    }

    static func decibels(forScaleFraction fraction: Double) -> Double {
        clampedDecibels(minimumDB + min(max(fraction, 0), 1) * (maximumDB - minimumDB))
    }
}

/// 声音的渐变窗口就是共用的 `FadeWindow`（字段、`none`、`isEmpty`、转场仲裁的
/// `suppressing` 和三重夹紧都在 VideoEditFadeWindow.swift）。下面只放声音专属的
/// 那一个口径：主轨转场那条边怎么算。
typealias AudioFadeWindow = FadeWindow

extension FadeWindow {
    /// 主轨某一段最终生效的音量斜坡（预览和成片是同一份混音）。
    ///
    /// 转场的交叉淡变**就是**靠这里的斜坡实现的（A/B 两条合成音轨一条淡出、一条淡入），
    /// 所以有转场的边要换成转场时长本身；用户在那条边设的渐变让位，不叠加。
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
}

extension EditClip {
    /// 「分离音频」造出来的那一段：同一个源文件、只取声音，挂在 `linkGroup` 上。
    ///
    /// **声音的设置跟着走**：音量、音量曲线、渐入渐出、声音场景都是这段声音自己的属性，
    /// 分离之后视频那段被静音，留在它身上的这些设置就再也听不见了 —— 用户画好的
    /// 曲线凭空消失（2026-09-23 随音量曲线补上；在那之前渐入渐出也一直没跟过来）。
    func detachedAudio(linkGroup group: UUID) -> EditClip {
        var detached = EditClip(
            sourceURL: sourceURL,
            isAudioOnly: true,
            sourceStart: sourceStart,
            sourceDuration: sourceDuration,
            speed: speed,
            timelineStart: timelineStart,
            volume: volume,
            fadeInDuration: fadeInDuration,
            fadeOutDuration: fadeOutDuration,
            linkGroup: group,
            info: info,
            audioAssetDuration: info?.duration
        )
        detached.volumeCurve = volumeCurve
        detached.soundScene = soundScene
        return detached
    }

    /// 这一段实际生效的渐入/渐出（时间线秒）。夹紧规则见 `FadeWindow.clamped`
    /// —— 与画面渐变**同一份**，两边不许各夹各的。
    var audioFades: AudioFadeWindow {
        FadeWindow.clamped(fadeIn: fadeInDuration, fadeOut: fadeOutDuration, span: timelineDuration)
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

    /// 把所有段的音量/渐变/音量曲线、以及三级推子抹成同一个值，只留「合成结构」
    /// 那部分身份。推子和曲线同样只进 audioMix（见 docs/architecture/audio-mixer.md），
    /// 拖一下推子就重建一次整条预览的话，画面每拖一下闪一次。
    private func audioMixNeutralized() -> TimelineState {
        var copy = self
        copy.mutateAllClips { clip in
            clip.volume = 1
            clip.fadeInDuration = 0
            clip.fadeOutDuration = 0
            clip.volumeCurve = KeyframeTrack()
            // 声音场景：换种类、拖滑杆只进 audioMix（tap 背后的配置），抹平；**有没有**场景
            // 留着 —— 挂了场景的合成音轨最后一段后面要垫一截素材让余音散完，那是合成结构
            // （docs/architecture/sound-scenes.md）。
            if clip.soundScene != nil { clip.soundScene = SoundScene(kind: .room) }
        }
        copy.mainVolume = 1
        copy.masterVolume = 1
        for index in copy.overlayTracks.indices { copy.overlayTracks[index].volume = 1 }
        for index in copy.audioTracks.indices { copy.audioTracks[index].volume = 1 }
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
/// 上层视频轨的静音段压根不会被插进合成音轨，改它会改结构。
struct AudioMixPlan: Equatable, Sendable {
    /// 一条合成音轨上按插入顺序排下来的段。
    struct Lane: Equatable, Sendable {
        /// `CMPersistentTrackID`（就是 Int32），用它重建 input parameters。
        var trackID: Int32
        var clipIDs: [UUID]
        /// 主轨的声音要按转场仲裁算斜坡，上层视频轨/音频轨不用。
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
