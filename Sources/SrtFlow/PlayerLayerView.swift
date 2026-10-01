import AVFoundation
import AppKit

// MARK: - 预览画面的宿主：一个裸的 AVPlayerLayer
//
// 管什么：把 AVPlayer 的画面放进一个 NSView（视图的图层就是 AVPlayerLayer），按 resizeAspect 放。
// 不管什么：控件、全屏、画中画、系统的「正在播放」—— 那些是 AVKit 的 AVPlayerView 带的，这里一样都不要。
//
// 为什么不用 AVPlayerView（2026-10-01）：它内部的 AVPlayerController 会在主线程上问播放器 `currentTime`
// （rate 一变就问一次），播放器自己的队列一忙（多轨合成在拆音频管线）主线程就被堵住 —— 看门狗抓到暂停那一拍
// 578 ms；`controlsStyle = .none`、`updatesNowPlayingInfoCenter = false` 都拦不住它。案例：
// docs/bugfixes/2026-10-01-meter-current-time-blocks-main-thread.md。
//
// 调色（`FilterStackAttachment`）挂在这个视图的 `contentFilters` 上，和以前挂在 AVPlayerView 上是同一条路
// （docs/architecture/filters.md「地基」）；盖一块（`CoverHostView`）是叠在它上面的另一层，放法同样是
// resizeAspect，画布正好铺满时两层的画面重合。

final class PlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()

    var player: AVPlayer? {
        get { playerLayer.player }
        set { playerLayer.player = newValue }
    }

    var videoGravity: AVLayerVideoGravity {
        get { playerLayer.videoGravity }
        set { playerLayer.videoGravity = newValue }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor  // 和 AVPlayerView 一样黑底：画面放不满的那两条边
        wantsLayer = true
    }

    /// 视图的图层就是播放器图层：`contentFilters` 直接染到画面上。
    override func makeBackingLayer() -> CALayer { playerLayer }
}
