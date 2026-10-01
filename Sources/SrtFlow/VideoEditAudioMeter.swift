import Foundation
import os

// MARK: - 电平表：轨道头推子里的电平条 + 总电平表 + 爆音红灯
//
// 管什么：每条表的显示状态（回落、峰值保持、红灯）和「此刻多响」从哪来 —— 音频引擎每条轨的渲染块按拍把峰值交给
// 自己的无锁槽（`MeterSlot`），总表从混音器出口取；引擎换配置时整批登记进来（`registerSlots`），界面播放时按
// 30 帧/秒 `reading` 取走。不管什么：峰值怎么算出来（AudioEngine/AudioTrackRenderer.swift、TimelineAudioEngine.swift）。
//
// 2026-09-23 到 2026-10-01 这里是 AVPlayer 那条路的电平表：每条合成音轨挂 `MTAudioProcessingTap`、按绝对位置写进
// 采样环、界面扫环。tap 的七条实测约束（看不到 audioMix 的音量、换 mix 新建 tap 卡 0.6 秒、一条合成音轨只装一种源格式、
// 时间可以比 0 早……）随那条路一起退役，案例还在 docs/bugfixes/ 里。合同见 docs/architecture/audio-mixer.md。

/// 电平表的身份：某条时间线轨（主轨 / 某条 lane），或者总输出。
enum MeterKey: Hashable, Sendable {
    case track(TimelineRowHeightKey)
    case master
}

// MARK: - 读数

/// 一条电平表此刻该画成什么样（dB）。
struct MeterReading: Equatable, Sendable {
    var left: Double
    var right: Double
    /// 峰值保持的那一道（dB）。
    var hold: Double
    /// 这一遍播放里过过 0 dBFS（红灯；下一次开播自动熄）。
    var clipped: Bool

    static let silent = MeterReading(left: AudioGain.minimumDB, right: AudioGain.minimumDB,
                                     hold: AudioGain.minimumDB, clipped: false)
}

// MARK: - 引擎

/// 电平表的全部状态：每条表的槽、每条表的显示状态、红灯。音频线程写槽（无锁），主线程（界面）读，显示状态一把锁。
final class AudioMeterEngine: @unchecked Sendable {
    private struct State {
        /// 每条表一个无锁槽（MeterSlot）：渲染块按拍写峰值，这里取走。
        var slots: [MeterKey: MeterSlot] = [:]
        var display: [MeterKey: Display] = [:]
        var clipped: Set<MeterKey> = []
    }

    private struct Display {
        var level: (left: Double, right: Double) = (AudioGain.minimumDB, AudioGain.minimumDB)
        var hold = AudioGain.minimumDB
        var holdUntil = 0.0
        var updated = 0.0
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    /// 显示的回落速度（dB/秒）和峰值保持多久（秒）。
    static let fallRate = 24.0
    static let holdSeconds = 1.5

    init() {}

    /// 换了一条新的合成（预览重建）：槽和显示状态重来（引擎 `apply` 之后会重新登记槽）。
    func beginComposition() {
        lock.withLock { state in
            state.slots = [:]
            state.display = [:]
        }
    }

    /// 登记每条表的槽（引擎建图 / 换配置时整批换）。
    func registerSlots(_ slots: [MeterKey: MeterSlot]) {
        lock.withLock { $0.slots = slots }
    }

    /// 自检用：某条表的槽此刻的峰值（不清零）；没登记槽就是 nil。
    func slotPeak(for key: MeterKey) -> (left: Float, right: Float)? {
        lock.withLock { $0.slots[key] }?.peek()
    }

    /// 开播时把上一遍的红灯熄掉（「这一遍播下来爆没爆」）。
    func clearClips() {
        lock.withLock { $0.clipped = [] }
    }

    /// 这条表的红灯亮着吗（停播时界面不再读电平，但红灯要留着）。
    func isClipped(_ key: MeterKey) -> Bool {
        lock.withLock { $0.clipped.contains(key) }
    }

    /// 界面读一条表：取走槽里自上次以来的峰值（30 帧/秒读，就是最近 33 ms 的峰值），按回落速度和峰值保持平滑；
    /// 过了 0 dBFS 就把红灯点上（一直亮到下一次开播）。`at` 是播放头（秒），只为了和老接口一致；`now` 做平滑。
    func reading(for key: MeterKey, at time: Double, now: Double) -> MeterReading {
        lock.withLock { (state: inout State) -> MeterReading in
            let peak: (left: Float, right: Float) = state.slots[key]?.take() ?? (0, 0)
            if max(peak.left, peak.right) > 1 { state.clipped.insert(key) }
            var display = state.display[key] ?? Display()
            let elapsed = display.updated > 0 ? max(0, now - display.updated) : 0
            let left = Self.smoothed(display.level.left, peak.left, elapsed: elapsed)
            let right = Self.smoothed(display.level.right, peak.right, elapsed: elapsed)
            display.level = (left, right)
            let top = max(left, right)
            if top >= display.hold || now > display.holdUntil {
                display.hold = top
                display.holdUntil = now + Self.holdSeconds
            }
            display.updated = now
            state.display[key] = display
            return MeterReading(left: left, right: right, hold: display.hold, clipped: state.clipped.contains(key))
        }
    }

    /// 起音立刻跟上，回落按 `fallRate` 慢慢掉（表不会一跳一跳地闪）。
    private static func smoothed(_ previous: Double, _ sample: Float, elapsed: Double) -> Double {
        let fresh = AudioGain.decibels(fromLinear: Double(sample))
        return max(fresh, max(AudioGain.minimumDB, previous - fallRate * elapsed))
    }
}
