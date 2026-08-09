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
            // **判「有没有声音」只认 `EditClip.hasAudio`** —— 与
            // CompositionBuilder / VideoEditExportGraph 同一个属性。
            // 这里曾经写成 `if let info, !info.hasAudio { return }`，等于把
            // `info == nil` 当成「有声音」：宽容解码读回来的老工程、探测还没
            // 回来的导入中素材都是 info == nil，于是用户**听不到**的段落照样
            // 进快照。`hasAudio` 自己已经处理了纯音频 clip 的 info 为 nil
            //（`isAudioOnly ||`），2026-08-06 案例要的那条回退还在。
            guard clip.hasAudio else { return }
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

    // MARK: - 自动检测的探针来源

    /// 选中的探针：素材 + 已经抽好的音频片段。
    struct ProbeSelection {
        var clip: SoundClip
        var file: URL
        /// 抽取时用的源区间（词时间要按 `range.start` 补偿）。
        var range: SourceRange
        /// 前面被跳过的素材各自的原因（读不了 → 换下一段），面板/日志可用。
        var skipped: [(name: String, error: Error)]
    }

    /// 值得一试的探针候选：文件真实存在的，按可听快照原序。
    ///
    /// 文件不在磁盘上就连试都不用试（抽音频必然失败）。但**「文件在」远不等于
    /// 「音轨读得出来」** —— 无音轨的视频、半截文件都是文件存在的，所以这里
    /// 只做便宜的预筛，真正的判据是 `selectProbe` 里那次实际抽取。
    static func probeOrder(in clips: [SoundClip]) -> [SoundClip] {
        clips.filter { FileManager.default.fileExists(atPath: $0.url.path) }
    }

    /// 定下探针之后的 metadata 查询顺序：**探针打头**，其余按快照原序。
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
    static func metadataOrder(in clips: [SoundClip], probe: SoundClip) -> [SoundClip] {
        [probe] + clips.filter { $0.clipID != probe.clipID }
    }

    /// 按快照顺序**逐段真的试抽一次**，返回第一段能读出音频的素材。
    ///
    /// 为什么不能只看 `fileExists`（PR#22 复审第二轮 P2）：第一段完全可能是
    /// 一个无音轨的视频或半截文件，而后面就跟着一条正常的音频轨。只挑第一段
    /// 又不重试的话，`AudioWindowReader` 当场抛错，整个 Auto-detect 直接失败 ——
    /// 用户手里明明有可用的声音。
    ///
    /// 错误分流照抄 `collectWindows` 的责任面（2026-08-06 案例「catch 面 =
    /// 责任面」）：
    /// - **素材自己的错**（无音轨、解码失败）→ 记下来换下一段；
    /// - **基础设施错误**（临时目录建不了、PCM 造不出）→ 直接上抛，不许伪装
    ///   成「素材不可读」；
    /// - **取消** → 直接上抛。
    ///
    /// - Parameter extract: 抽取动作。生产传 `AudioWindowReader.extract`；
    ///   自检可以注入一个会挑着失败的实现来验分流策略。
    /// - Returns: 全部候选都读不出音频时返回 nil（调用方报「素材读不了」）。
    static func selectProbe(
        in clips: [SoundClip],
        probeSeconds: Double,
        extract: (_ clip: SoundClip, _ range: SourceRange) async throws -> URL
    ) async throws -> ProbeSelection? {
        var skipped: [(name: String, error: Error)] = []
        for clip in probeOrder(in: clips) {
            let range = SourceRange(
                start: clip.sourceStart,
                end: clip.sourceStart + min(probeSeconds, clip.sourceDuration)
            )
            do {
                let file = try await extract(clip, range)
                return ProbeSelection(clip: clip, file: file, range: range, skipped: skipped)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as AudioWindowReader.InfrastructureError {
                throw error
            } catch {
                skipped.append((clip.name, error))
            }
        }
        return nil
    }
}

extension SubtitleAudibleClips.SoundClip: Equatable {
    static func == (
        lhs: SubtitleAudibleClips.SoundClip, rhs: SubtitleAudibleClips.SoundClip
    ) -> Bool {
        lhs.clipID == rhs.clipID
    }
}
