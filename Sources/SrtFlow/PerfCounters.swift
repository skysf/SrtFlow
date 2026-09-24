import Foundation
import os

// 预览性能测试的工作量计数（docs/architecture/preview-perf-ratchet.md）。
//
// GitHub 托管的 macOS runner 是虚拟机，读不到 CPU 指令计数器（2026-09-24 探针实测
// 三台全是 0），CPU 时间在不同 runner 之间又差到两倍 —— 所以 CI 上卡的不是「花了
// 多少 CPU」，而是「做了多少件活」：哪个视图的 body 被重算了几次、合成重建了几次、
// 开了几次素材文件。这些是精确的整数，同一份代码在哪台机器上跑都一样。
//
// **只有性能测试开着时才记账**（环境变量 `SRTFLOW_BENCH_OUT`，见 PreviewBench.swift）。
// 平时每个埋点只读一个静态布尔值就返回：不加锁、不分配、不算类型名。

enum PerfCounters {
    /// 性能测试的结果文件。设了它才跑测试、才记账。
    ///
    /// 键写在这里而不是 PreviewBench 里：好几个自检只编模型和合成构建器，
    /// 引用到 PreviewBench 就得把整个编辑器一起编进去。
    static let outputKey = "SRTFLOW_BENCH_OUT"

    /// 性能测试开着没有。进程启动时定下，之后不变。
    static let isEnabled = ProcessInfo.processInfo.environment[outputKey] != nil

    /// 视图的 body 被求值了一次。**每个** SwiftUI 视图和修饰器的 body 第一行都是
    /// `let _ = PerfCounters.body(Self.self)`（`checks/preview-perf-wiring.sh` 钉着）：
    /// 漏插一个，那个视图每跳一下都在重算，账上也看不见。
    static func body<V>(_ type: V.Type) {
        guard isEnabled else { return }
        record(.body, type)
    }

    /// `NSViewRepresentable.updateNSView` 被调了一次（包着 AppKit 视图的那几个没有
    /// body，父视图一重算它就被调，代价藏在这里）。
    static func update<V>(_ type: V.Type) {
        guard isEnabled else { return }
        record(.update, type)
    }

    /// `Canvas` 的绘制闭包跑了一次 —— 真正一笔一笔画东西的地方（波形、缩略图、
    /// 标尺、电平表、音量线）。`type` 传所在视图的 `Self.self`。
    static func canvas<V>(_ type: V.Type) {
        guard isEnabled else { return }
        record(.canvas, type)
    }

    /// 视图以外的活。
    static func event(_ event: Event) {
        guard isEnabled else { return }
        store.withLock { $0.events[event, default: 0] += 1 }
    }

    enum Event: String, CaseIterable {
        /// 时钟往外发了一次播放时间（播放时每秒 20 次，每次都会叫醒所有订阅它的视图）。
        case clockTick = "clock.tick"
        /// 预览换上了一个新的播放条目（`replaceCurrentItem`，画面会闪一下）。
        case playerItemAttach = "player.itemAttach"
        /// 建了一次预览合成。
        case compositionBuild = "composition.build"
        /// 建合成时开了一个素材文件（`AVURLAsset`）。
        case compositionAssetOpen = "composition.assetOpen"
        /// 新建了一个电平表 tap。同一条合成里换 mix 该复用旧的：新建会让播放卡
        /// 0.6 秒（docs/architecture/audio-mixer.md）。
        case meterTapCreate = "meters.tapCreate"
        /// 只换 audioMix、不重建合成的快路径走通了一次。
        case audioMixRefresh = "audioMix.refresh"
    }

    /// 到此刻为止的全部计数，键形如 `body:VideoEditTimelineView`、`event:clock.tick`。
    static func snapshot() -> [String: Int] {
        store.withLock { store in
            var out: [String: Int] = [:]
            for (key, count) in store.counts {
                out["\(key.kind.rawValue):\(store.names[key.type] ?? "?")"] = count
            }
            for (event, count) in store.events {
                out["event:\(event.rawValue)"] = count
            }
            return out
        }
    }

    static func reset() {
        store.withLock { store in
            store.counts.removeAll(keepingCapacity: true)
            store.events.removeAll(keepingCapacity: true)
        }
    }

    // MARK: - 私有

    private enum Kind: String {
        case body, update, canvas
    }

    private struct Key: Hashable {
        let kind: Kind
        let type: ObjectIdentifier
    }

    private struct Store {
        var counts: [Key: Int] = [:]
        var events: [Event: Int] = [:]
        /// 类型名只算一次（`String(describing:)` 不便宜，body 一秒要被调几百次）。
        var names: [ObjectIdentifier: String] = [:]
    }

    private static let store = OSAllocatedUnfairLock(initialState: Store())

    private static func record<V>(_ kind: Kind, _ type: V.Type) {
        let id = ObjectIdentifier(type)
        store.withLock { store in
            if store.names[id] == nil { store.names[id] = String(describing: type) }
            store.counts[Key(kind: kind, type: id), default: 0] += 1
        }
    }
}
