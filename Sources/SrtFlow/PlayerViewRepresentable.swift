import AVFoundation
import SwiftUI

// 播放器视图从 `VideoPreviewView.swift` 拆出来（2026-09-21）。
//
// 拆分的理由很实在：那个文件里原本混着两件事 —— `PlayerClock`（纯模型，链式
// seek 和悬停 peek 的状态机）和这个视图。`scripts/check-player-clock.sh` 只想要
// 前者，却因为同在一个文件里，被迫连带编进视图的全部依赖；这一刀给视图加了
// 「此刻的调色」之后，那条依赖一路牵到 `TimelineState`，小检查当场编不动。
//
// 2026-10-01 起宿主是 `PlayerLayerView`（裸 AVPlayerLayer），不再是 AVKit 的 AVPlayerView：
// 后者内部的控制器会在主线程上问播放器要时间、把主线程堵住（见 PlayerLayerView.swift 文件头）。
// 这里不 import AVKit，`checks/player-time-no-sync-read.sh` 钉着。

/// 预览画面 + 此刻挂的调色。两个宿主都用它：剪辑页（挂调色）和烧字幕预览（不认识滤镜，默认空）。
struct PlayerViewRepresentable: NSViewRepresentable {
    let player: AVPlayer
    /// 此刻要挂的调色（时间轴上的滤镜段）。默认空 —— 烧字幕预览那个宿主
    /// 不认识滤镜，也不该被它影响。
    var filterStack: FilterStack = .empty

    func makeCoordinator() -> FilterStackAttachment { FilterStackAttachment() }

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.player = player
        return view
    }

    func updateNSView(_ nsView: PlayerLayerView, context: Context) {
        PerfCounters.update(Self.self)
        if nsView.player !== player { nsView.player = player }
        // 每秒会被调二十次（时钟 0.05s 一跳），所以「挂的还是不是上次那套」
        // 的判断在 attachment 里做，这里无条件调。
        context.coordinator.apply(filterStack, to: nsView)
    }
}
