import AVKit
import SwiftUI

// 播放器视图从 `VideoPreviewView.swift` 拆出来（2026-09-21）。
//
// 拆分的理由很实在：那个文件里原本混着两件事 —— `PlayerClock`（纯模型，链式
// seek 和悬停 peek 的状态机）和这个视图。`scripts/check-player-clock.sh` 只想要
// 前者，却因为同在一个文件里，被迫连带编进视图的全部依赖；这一刀给视图加了
// 「此刻的调色」之后，那条依赖一路牵到 `TimelineState`，小检查当场编不动。

/// 用 AppKit 原生 AVPlayerView 代替 SwiftUI 的 VideoPlayer：
/// VideoPlayer 走私有框架 _AVKit_SwiftUI，在某些系统版本上实例化即崩溃。
struct PlayerViewRepresentable: NSViewRepresentable {
    let player: AVPlayer
    /// 烧字幕预览给 `.none`：自带的控件浮在画面底部，正好压住字幕，
    /// 那一块恰恰是要看的地方，所以那边自己画播放条。
    var controlsStyle: AVPlayerViewControlsStyle = .inline
    /// 此刻要挂的调色（时间轴上的滤镜段）。默认空 —— 烧字幕预览那个宿主
    /// 不认识滤镜，也不该被它影响。
    var filterStack: FilterStack = .empty

    func makeCoordinator() -> FilterStackAttachment { FilterStackAttachment() }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = controlsStyle
        view.showsFullScreenToggleButton = controlsStyle != .none
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
        if nsView.controlsStyle != controlsStyle { nsView.controlsStyle = controlsStyle }
        // 每秒会被调二十次（时钟 0.05s 一跳），所以「挂的还是不是上次那套」
        // 的判断在 attachment 里做，这里无条件调。
        context.coordinator.apply(filterStack, to: nsView)
    }
}

