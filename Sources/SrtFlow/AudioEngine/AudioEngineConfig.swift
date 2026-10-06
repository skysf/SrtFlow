import Foundation

// MARK: - 音频引擎要播什么：从时间线算出来的一份纯值
//
// 管什么：哪条轨、哪一段、从素材的哪一秒起、在时间线的哪一段出声、每一刻多大声（段的增益）、轨道推子、总推子、
// 总长。换一份配置 = 换一个值，引擎按它播。
// 不管什么：读文件、混音、时钟（AudioEngine/ 下的其余文件）。
//
// 段落规则和 VideoEditCompositionBuilder 往合成里插声音的规则**是同一份**：哪些段出声（整轨隐藏、单段隐藏、
// 还在转静帧的占位块不出；主轨和上层轨静音的段不出；音频轨静音 = 增益 0，这里直接不出）、从哪儿起（主轨接缝
// 不到 `mainGapTolerance` 的零头接在上一段末尾）、首尾定格那两截留空（声音没有定格）。增益用的是
// AudioGainRamps.addVolumeRamps 那一张 GainTable（音量 × 渐变 × 曲线；主轨转场的交叉淡变仲裁在
// FadeWindow.previewMainTrack）。引擎接管之后 builder 不再插音轨（PR3），这份就是声音唯一的账。
// 方案：docs/plans/2026-10-01-audio-engine.md；自检：scripts/check-audio-engine.sh（和 AVFoundation 的混音逐窗口比）。

struct AudioEngineConfig: Sendable {
    /// 时间线上出声的一段。
    struct Segment: Sendable {
        let clipID: UUID
        let url: URL
        /// 这段在时间线上从哪一秒起出声（首帧定格那一截之后）。
        let start: Double
        /// 到哪一秒为止（不含；尾帧定格那一截之前）。素材比账上短的话读到素材末尾就静音。
        let end: Double
        /// `start` 那一刻对应素材的哪一秒。
        let sourceStart: Double
        /// 变速倍数（1 = 原速）：素材秒 = sourceStart + (t − start) × speed。
        let speed: Double
        /// 段自己的增益（音量 × 渐变 × 曲线；静音 = 0），按时间线秒取。**效果之前**乘（声音场景在它后面）。
        let gain: GainTable.Sampler
        /// 挂的声音场景（nil = 没有）。效果链在渲染块里跑，余音越过段尾（docs/architecture/sound-scenes.md）。
        let scene: SoundScene?
        /// 场景输出乘多少才和原声一样响（`SceneLoudness`）。
        let compensation: Float

        var duration: Double { end - start }

        /// 流开了之后就改不了的那部分（`SegmentStream` 开流时抄死 start / end / sourceStart / speed、按 url 开文件）：
        /// 有一项不同就得重开流。增益、场景的参数、补偿不在里面 —— 它们能在流活着时换（`updateGains`）；有没有场景在
        ///（效果链是开流时建的）。`TimelineAudioEngine.sameStructure` 按它比。2026-10-01 到 10-06 只比 clipID：挪一段 /
        /// 裁头尾 / 变速之后画面挪了、声音还在原地（docs/bugfixes/2026-10-06-audio-engine-replace-keeps-old-segment-positions.md）。
        struct Structure: Equatable {
            let clipID: UUID
            let url: URL
            let start: Double
            let end: Double
            let sourceStart: Double
            let speed: Double
            let hasScene: Bool
        }

        var structure: Structure {
            Structure(clipID: clipID, url: url, start: start, end: end, sourceStart: sourceStart, speed: speed, hasScene: scene != nil)
        }
    }

    /// 时间线上的一条轨：主轨、每条上层视频轨、每条音频轨各一条（有声音才算）。
    struct Track: Sendable {
        /// 给日志和自检看的名字（main / V2 / A1…）。
        let name: String
        /// 轨道头上哪一条电平表（主轨 `.track(.main)`，其余按轨的 id）。渲染块把这条轨听到的采样写进它的环。
        let meterKey: MeterKey
        /// 轨道推子（线性）。
        let fader: Float
        /// 按 `start` 排好；主轨转场处前后两段相叠。
        let segments: [Segment]
    }

    var tracks: [Track]
    /// 总推子（线性）。
    var master: Float
    /// 时间线总长（秒）：成片正好这么长。
    var duration: Double

    static let empty = AudioEngineConfig(tracks: [], master: 1, duration: 0)

    /// `requested` 传**用户那一份**：这里自己排序、展开转场（和 builder 插画面同一份几何，展开只许一次）。
    static func make(from requested: TimelineState) -> AudioEngineConfig {
        var state = requested
        state.sortMainClipsByStart()
        state = state.expandingTransitionHandles()
        var tracks: [Track] = []

        var main: [Segment] = []
        var previousMainEnd = 0.0
        for (index, clip) in state.mainClips.enumerated() {
            guard !state.mainHidden, !clip.isHidden, !clip.needsStillConversion else { continue }
            // 不到 mainGapTolerance 的缝不是空隙：接在前一段真正的末尾上（builder 同一口径）。
            let gap = clip.timelineStart - previousMainEnd
            let startsAt = gap > 0 && gap < TimelineState.mainGapTolerance ? previousMainEnd : clip.timelineStart
            previousMainEnd = clip.timelineEnd
            guard clip.hasAudio, !clip.isMuted else { continue }
            let fades = AudioFadeWindow.previewMainTrack(
                clip: clip,
                transitionBefore: index > 0 ? state.transitionOverlap(afterMainIndex: index - 1) : 0,
                transitionAfter: state.transitionOverlap(afterMainIndex: index)
            )
            if let segment = segment(for: clip, at: startsAt, fades: fades) { main.append(segment) }
        }
        tracks.append(Track(name: "main", meterKey: .track(.main), fader: Float(state.mainVolume), segments: main))

        for (index, lane) in state.overlayTracks.enumerated() where !lane.isHidden {
            var segments: [Segment] = []
            for clip in ClipVisibility.visible(lane.clips).sorted(by: { $0.timelineStart < $1.timelineStart })
            where !clip.needsStillConversion && clip.hasAudio && !clip.isMuted {
                if let segment = segment(for: clip, at: clip.timelineStart, fades: clip.audioFades) {
                    segments.append(segment)
                }
            }
            tracks.append(Track(name: "V\(index + 2)", meterKey: .track(.lane(lane.id)), fader: Float(lane.volume), segments: segments))
        }

        for (index, lane) in state.audioTracks.enumerated() where !lane.isHidden {
            var segments: [Segment] = []
            for clip in ClipVisibility.visible(lane.clips).sorted(by: { $0.timelineStart < $1.timelineStart })
            where !clip.isMuted {
                if let segment = segment(for: clip, at: clip.timelineStart, fades: clip.audioFades) {
                    segments.append(segment)
                }
            }
            tracks.append(Track(name: "A\(index + 1)", meterKey: .track(.lane(lane.id)), fader: Float(lane.volume), segments: segments))
        }

        return AudioEngineConfig(
            tracks: tracks.filter { !$0.segments.isEmpty },
            master: Float(state.masterVolume),
            duration: state.duration
        )
    }

    /// 一段的出声范围和增益。和 builder 的 `insert` 同一笔账：首帧定格留空、素材不够长在读的那一侧收口。
    /// 增益表的钉点（`previousEnd`）钉在段起点：引擎段外本来就没有声音（AudioGainTable.swift）。
    private static func segment(for clip: EditClip, at: Double, fades: AudioFadeWindow) -> Segment? {
        let speed = max(0.05, clip.speed)
        let sourceDuration = clip.renderSourceDuration
        guard sourceDuration > 0.01 else { return nil }
        let start = at + clip.renderHoldHead
        var table = GainTable()
        AudioGainRamps.addVolumeRamps(
            table: &table, clip: clip, fades: fades, previousEnd: clip.timelineStart, gainScale: 1
        )
        return Segment(
            clipID: clip.id, url: clip.sourceURL, start: start, end: start + sourceDuration / speed,
            sourceStart: clip.renderSourceStart, speed: speed, gain: table.sampler(),
            scene: clip.soundScene, compensation: clip.soundScene.map(SceneLoudness.compensation(for:)) ?? 1
        )
    }
}
