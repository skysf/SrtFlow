import AVFoundation
import Foundation

// MARK: - 预览的声音：只换 audioMix 的快路径、拖推子的即时试听，和（开关开着时）音频引擎的接线
//
// 管什么：改音量 / 渐变 / 曲线 / 推子但合成结构没变时，预览的声音怎么跟上 —— 两条路：
// - 开关关着（默认，正式版）：换正在播的条目上的 audioMix（`AudioMixBuilder.make`，和整条重建同一份）。
// - 开关开着（`AudioEngineFlag`）：把新配置交给引擎（`TimelineAudioEngine.updateGains`），不碰播放器。
// 还有引擎的宿主 `PreviewAudioEngineHost`：持有引擎、每次重建之后换整份配置、第一次建的时候挂到时钟上。
// 不管什么：合成怎么建（VideoEditCompositionBuilder）、引擎本身（AudioEngine/）。
//
// 2026-10-01 从 VideoEditProject.swift 搬出来（它在 600 行基线里只许降不许涨），顺手加了引擎这条路。
// 方案：docs/plans/2026-10-01-audio-engine.md；长期约束：docs/architecture/audio-engine.md。

/// 开关开着时，预览的声音走引擎：持有引擎、把每次重建 / 换 mix 的配置交给它、给 PlayerClock 当主时钟。
@MainActor
final class PreviewAudioEngineHost {
    static var isEnabled: Bool { AudioEngineFlag.isEnabled }

    private(set) var engine: TimelineAudioEngine?
    /// 渲染块里环里没有数据、只能当静音的帧数（累计）。冒烟看它。
    var underrunFrames: Int { engine?.underrunFrames ?? 0 }

    /// 重建预览之后：整份配置换掉。第一次建引擎、起图、挂到时钟上（从此声音是主时钟）。
    func apply(_ config: AudioEngineConfig, clock: PlayerClock) {
        if let engine {
            engine.replace(config: config)
            return
        }
        guard let engine = try? TimelineAudioEngine(config: config, mode: .realtime) else { return }
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
    /// 时间线一变就（去抖后）重建预览合成。播放头位置和播放状态都要还原，
    /// 只把新的 audioMix 换到正在播的条目上，**不碰画面**。
    ///
    /// 音量和渐入渐出只进 audioMix，走完整重建的话要
    /// `replaceCurrentItem`，画面会闪一下（用户报的问题）。返回 false 表示
    /// 这条快路径此刻用不上（还没建过预览、或者合成已经被换掉），调用方
    /// 应当退回 `scheduleRebuild()`。
    ///
    /// 前提是**合成结构没变**，判据在 `TimelineState.differsOnlyInAudioMix`，
    /// 别在这里另立一套。
    @discardableResult
    func refreshAudioMix() -> Bool {
        // 重建正在路上时别插队：它马上会带着新的 plan 和 mix 落地，
        // 这时候按旧 plan 算出来的 mix 会被它覆盖，白算一次还可能对不上。
        guard !rebuildStatus.isRebuilding else { return false }
        if PreviewAudioEngineHost.isEnabled {
            guard audioEngineHost.engine != nil else { return false }
            PerfCounters.event(.audioMixRefresh)
            audioEngineHost.updateGains(AudioEngineConfig.make(from: state))
            return true
        }
        guard let plan = audioPlan, !plan.lanes.isEmpty,
              let item = clock.player.currentItem else { return false }
        PerfCounters.event(.audioMixRefresh)
        item.audioMix = VideoEditCompositionBuilder.makeAudioMix(state: state, plan: plan, meters: meters)
        return true
    }

    /// 拖音量线 / 推子的**过程中**让预览当场听得见，但**不写 `state`**（时间线拖动 §0：
    /// 每一拍写 `state` 会让读它的视图每一拍都重算、还要重挂一次自动保存）。拿一份临时状态算
    /// audioMix 直接换上；节流到 ~20 次/秒。松手时的真提交走 `perform` → 快路径，
    /// 手势中途放弃时调一次 `refreshAudioMix()` 换回真状态的 mix。
    ///
    /// 同一个 `makeAudioMix`、同一份 plan —— 和快路径、整条重建是同一笔账。引擎那条路同理：
    /// 同一个 `AudioEngineConfig.make`。
    func previewAudioLive(_ mutate: (inout TimelineState) -> Void) {
        let now = CACurrentMediaTime()
        guard now - lastLiveAudioPreview > 0.05, !rebuildStatus.isRebuilding else { return }
        if PreviewAudioEngineHost.isEnabled {
            guard audioEngineHost.engine != nil else { return }
            lastLiveAudioPreview = now
            var preview = state
            mutate(&preview)
            audioEngineHost.updateGains(AudioEngineConfig.make(from: preview))
            return
        }
        guard let plan = audioPlan, !plan.lanes.isEmpty,
              let item = clock.player.currentItem else { return }
        lastLiveAudioPreview = now
        var preview = state
        mutate(&preview)
        item.audioMix = VideoEditCompositionBuilder.makeAudioMix(state: preview, plan: plan, meters: meters)
    }
}
