import AVFoundation
import Foundation

// MARK: - 预览的声音：音频引擎的接线 —— 只换增益的快路径、拖推子的即时试听
//
// 管什么：改音量 / 渐变 / 曲线 / 推子但合成结构没变时，预览的声音怎么跟上：按新状态算一份 `AudioEngineConfig`
// 交给引擎（`TimelineAudioEngine.updateGains`），不碰播放器、画面不闪。还有引擎的宿主 `PreviewAudioEngineHost`：
// 持有引擎、每次重建之后换整份配置、第一次建的时候挂到时钟上（从此声音是主时钟）。
// 不管什么：合成怎么建（VideoEditCompositionBuilder，只有画面）、引擎本身（AudioEngine/）。
//
// 2026-10-01 从 VideoEditProject.swift 搬出来（它在 600 行基线里只许降不许涨）；同日 PR3b 删掉了 AVPlayer 那条路
// （换正在播的条目上的 audioMix）和迁移期的开关。方案：docs/plans/2026-10-01-audio-engine.md；长期约束：docs/architecture/audio-engine.md。

/// 预览的声音走引擎：持有引擎、把每次重建 / 换增益的配置交给它、给 PlayerClock 当主时钟。
@MainActor
final class PreviewAudioEngineHost {
    private(set) var engine: TimelineAudioEngine?
    /// 渲染块里环里没有数据、只能当静音的帧数（累计）。冒烟看它。
    var underrunFrames: Int { engine?.underrunFrames ?? 0 }

    /// 重建预览之后：整份配置换掉。第一次建引擎、起图、挂到时钟上（从此声音是主时钟）；电平表交给渲染块写。
    func apply(_ config: AudioEngineConfig, clock: PlayerClock, meters: AudioMeterEngine) {
        if let engine {
            engine.replace(config: config)
            return
        }
        guard let engine = try? TimelineAudioEngine(config: config, mode: .realtime, meters: meters) else { return }
        self.engine = engine
        // GUI 冒烟的静音钩子（和 PlayerClock 同一个开关）：验播放时别往正在用机器的人耳朵里外放。
        if ProcessInfo.processInfo.environment["SRTFLOW_SMOKE_MUTE"] != nil { engine.mute() }
        do {
            try engine.start()
        } catch {
            self.engine = nil
            return
        }
        clock.attachAudioSource(engine)
    }

    /// 只换增益（结构没变）。
    func updateGains(_ config: AudioEngineConfig) { engine?.updateGains(config: config) }

    /// 试听让路（1 = 不让）。
    func duck(_ gain: Float) { engine?.duck(gain) }
}

extension VideoEditProject {
    /// 改音量/渐变时只换引擎的增益，不重建整条预览。
    ///
    /// 走完整重建的话要 `replaceCurrentItem`，画面会闪一下（用户报的问题）。返回 false 表示
    /// 这条快路径此刻用不上（还没建过预览 / 引擎），调用方应当退回 `scheduleRebuild()`。
    ///
    /// 前提是**合成结构没变**，判据在 `TimelineState.differsOnlyInAudioMix`，
    /// 别在这里另立一套。
    @discardableResult
    func refreshAudioMix() -> Bool {
        // 重建正在路上时别插队：它马上会带着整份新配置落地，这时候按旧状态算的增益会被它覆盖，白算一次。
        guard !rebuildStatus.isRebuilding, audioEngineHost.engine != nil else { return false }
        PerfCounters.event(.audioMixRefresh)
        audioEngineHost.updateGains(AudioEngineConfig.make(from: state))
        return true
    }

    /// 拖音量线 / 推子的**过程中**让预览当场听得见，但**不写 `state`**（时间线拖动 §0：
    /// 每一拍写 `state` 会让读它的视图每一拍都重算、还要重挂一次自动保存）。拿一份临时状态算
    /// 配置直接交给引擎；节流到 ~20 次/秒。松手时的真提交走 `perform` → 快路径，
    /// 手势中途放弃时调一次 `refreshAudioMix()` 换回真状态的增益。
    ///
    /// 同一个 `AudioEngineConfig.make` —— 和快路径、整条重建是同一笔账。
    func previewAudioLive(_ mutate: (inout TimelineState) -> Void) {
        let now = CACurrentMediaTime()
        guard now - lastLiveAudioPreview > 0.05, !rebuildStatus.isRebuilding, audioEngineHost.engine != nil else { return }
        lastLiveAudioPreview = now
        var preview = state
        mutate(&preview)
        audioEngineHost.updateGains(AudioEngineConfig.make(from: preview))
    }
}
