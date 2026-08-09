import Foundation
import SrtFlowCore

// 字幕生成的**素材侧快照**：谁在响、拿谁做探针、按什么顺序查音轨 metadata。
//
// 独立成文件有两个原因：
// 1. TranscriptionTask 本体是 @available(macOS 26) 的 @MainActor 状态机，
//    自检编不动；这里全是纯值逻辑，能被 checks/ProjectFile 直接编进去，
//    于是「生产接线」而不只是「纯函数」可以被守卫钉住。
// 2. 「可听性只有一份合同」（2026-08-06 案例的教训）：把它摆在一个有名字的
//    地方，下一个消费者才知道要抄哪份，而不是自己发明一套子集。

enum SubtitleAudibleClips {

    /// 一段确实会被听见的素材（已按可听合同过滤）。
    struct SoundClip {
        var clipID: UUID
        var name: String
        var url: URL
        var fingerprint: String
        /// 探测到的素材总时长；纯音频 clip 可能拿不到（info == nil）。
        var knownAssetDuration: Double?
        var sourceStart: Double
        var sourceDuration: Double
        var timelineStart: Double
        var speed: Double
        var laneRank: Int
    }

    /// 出声 clip 清单 —— 与预览/导出同一份「实际可听」合同
    /// （VideoEditCompositionBuilder 先例）：mainHidden 跳过整个主轨、
    /// isHidden 的 lane 当不存在、静音或音量为 0 的 clip 不算出声。
    ///
    /// **字幕生成一侧的所有素材消费者都必须从这里取**（转写、探针、音轨
    /// metadata、面板的可用性判断）。任何「我只要主轨和音频轨就够了」的
    /// 简化都会重新分叉出一份无视眼睛/静音的声音来源。
    static func soundClips(in state: TimelineState) -> [SoundClip] {
        var result: [SoundClip] = []
        func add(_ clip: EditClip, laneRank: Int) {
            guard !clip.isMuted, clip.volume > 0, clip.stillImageURL == nil else { return }
            if let info = clip.info, !info.hasAudio { return }
            result.append(SoundClip(
                clipID: clip.id,
                name: clip.name,
                url: clip.sourceURL,
                // 纯音频 clip 的 info 可能是 nil，指纹回退到磁盘大小/mtime，
                // 避免「同路径换了文件还命中旧缓存」。
                fingerprint: TranscriptSidecarStore.fingerprint(
                    forFileAt: clip.sourceURL,
                    knownBytes: clip.info?.fileBytes,
                    knownDuration: clip.info?.duration
                ),
                knownAssetDuration: clip.info?.duration,
                sourceStart: clip.sourceStart,
                sourceDuration: clip.sourceDuration,
                timelineStart: clip.timelineStart,
                speed: clip.speed,
                laneRank: laneRank
            ))
        }
        if !state.mainHidden {
            for clip in state.mainClips { add(clip, laneRank: 0) }
        }
        for (index, lane) in state.overlayTracks.enumerated() where !lane.isHidden {
            for clip in lane.clips { add(clip, laneRank: 1 + index) }
        }
        for (index, lane) in state.audioTracks.enumerated() where !lane.isHidden {
            for clip in lane.clips {
                add(clip, laneRank: 1 + state.overlayTracks.count + index)
            }
        }
        return result
    }

    /// 自动检测阶段的素材输入：探针素材 + 音轨 metadata 的查询顺序。
    struct DetectionSources: Equatable {
        /// 真正被抽出来做探针的那一段（文件必须真实存在，否则抽不出音频）。
        var probe: SoundClip
        /// metadata 的查询顺序：**探针打头**，其余按可听快照原序。
        var metadataOrder: [SoundClip]
    }

    /// 从冻结的可听快照里挑探针、排出 metadata 查询顺序。
    ///
    /// 「先问探针自己」不是排版讲究，是合同：音轨 metadata 是自动检测的
    /// **最高优先级候选**（还是唯一允许触发模型下载的那个），它必须来自真正
    /// 会被听的那段声音。隐藏的英文主轨 + 可听的日文 overlay 就是反例 ——
    /// 拿英文 metadata 当首选候选、却拿日文 overlay 做探针，等于给检测喂了
    /// 互相矛盾的两份输入（PR#22 复审 P1）。
    ///
    /// 入参只接受 `soundClips(in:)` 的产物，所以 `mainHidden` / `lane.isHidden`
    /// / `isMuted` / `volume <= 0` / 静帧图片段已经全被滤掉了 —— 这里**不再
    /// 重复一套判据**，也不许回头去枚举 `TimelineState`。
    ///
    /// - Returns: 快照里一个真实存在的文件都没有时返回 nil（调用方报「素材
    ///   读不了，请重新链接」）。
    static func detectionSources(in clips: [SoundClip]) -> DetectionSources? {
        guard let probe = clips.first(where: {
            FileManager.default.fileExists(atPath: $0.url.path)
        }) else { return nil }
        return DetectionSources(
            probe: probe,
            metadataOrder: [probe] + clips.filter { $0.clipID != probe.clipID }
        )
    }
}

extension SubtitleAudibleClips.SoundClip: Equatable {
    static func == (
        lhs: SubtitleAudibleClips.SoundClip, rhs: SubtitleAudibleClips.SoundClip
    ) -> Bool {
        lhs.clipID == rhs.clipID
    }
}
