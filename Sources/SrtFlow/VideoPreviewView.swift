import SwiftUI
import AVKit
import SrtFlowCore

/// Owns the AVPlayer and publishes playback time for subtitle sync.
final class PlayerClock: ObservableObject {
    @Published private(set) var time: TimeInterval = 0
    @Published private(set) var hasVideo = false
    @Published private(set) var isPlaying = false

    let player = AVPlayer()
    private var timeObserver: Any?
    private var rateObservation: NSKeyValueObservation?

    /// 链式 seek（Apple QA1820）的两个状态：上一个 seek 还没完成时只记下最新目标，
    /// 完成后再续发。主线程读写。
    private var isScrubSeeking = false
    private var pendingScrubTarget: TimeInterval?

    /// - Parameter observationInterval: 时间回调的间隔。烧字幕预览要靠它切换叠在
    ///   画面上的那句字幕，所以给得比字幕编辑器密一些。
    init(observationInterval: TimeInterval = 0.25) {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: observationInterval, preferredTimescale: 600),
            queue: .main
        ) { [weak self] cmTime in
            self?.time = cmTime.seconds
        }
        // 播放/暂停按钮要跟着实际状态走：播到片尾时 rate 会自己变 0，
        // 光靠自己按下去的那一下记状态会不准。
        rateObservation = player.observe(\.rate, options: [.initial, .new]) { [weak self] player, _ in
            let playing = player.rate > 0
            if Thread.isMainThread {
                self?.isPlaying = playing
            } else {
                DispatchQueue.main.async { self?.isPlaying = playing }
            }
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        rateObservation?.invalidate()
        // 视图被销毁（比如切走了侧边栏那一栏）时别让声音还在响。
        player.pause()
    }

    func attach(url: URL, autoplay: Bool = true) {
        pendingScrubTarget = nil
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        hasVideo = true
        time = 0
        if autoplay { player.play() }
    }

    /// 换上一个现成的条目（时间线合成不是 URL，`attach(url:)` 用不上）。
    /// 播放头交给调用方自己恢复。
    func attachItem(_ item: AVPlayerItem) {
        pendingScrubTarget = nil
        player.replaceCurrentItem(with: item)
        hasVideo = true
    }

    func detach() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        pendingScrubTarget = nil
        hasVideo = false
        time = 0
    }

    /// - Parameter precise: 松手和按字幕跳转时给 `true`（立刻精确定位）；拖动/悬停
    ///   扫过的过程中给 `false` —— 也是零容差逐帧刷新，但走链式 seek 防洪。
    ///   注意不能退回「就近关键帧」的粗定位：合成条目的关键帧隔好几秒一个，
    ///   拖动中画面会看起来纹丝不动（docs/bugfixes/2026-08-03-scrub-preview-keyframe-snap.md）。
    func seek(to seconds: TimeInterval, precise: Bool = true) {
        let clamped = max(0, seconds)
        time = clamped
        if precise {
            pendingScrubTarget = nil
            player.seek(
                to: CMTime(seconds: clamped, preferredTimescale: 600),
                toleranceBefore: .zero, toleranceAfter: .zero
            )
        } else {
            scrub(to: clamped)
        }
    }

    /// 每个 mouse move 都直发 `player.seek` 会淹死解码器（在飞的 seek 被反复取消，
    /// 帧刷新率反而不稳）。这里串行化：在飞时只记目标，完成回调里续发最新的。
    private func scrub(to seconds: TimeInterval) {
        guard !isScrubSeeking else {
            pendingScrubTarget = seconds
            return
        }
        isScrubSeeking = true
        player.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero
        ) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isScrubSeeking = false
                if let next = self.pendingScrubTarget {
                    self.pendingScrubTarget = nil
                    self.scrub(to: next)
                }
            }
        }
    }

    func togglePlayback() {
        if player.rate > 0 { player.pause() } else { player.play() }
    }

    func pause() { player.pause() }
}

/// 用 AppKit 原生 AVPlayerView 代替 SwiftUI 的 VideoPlayer：
/// VideoPlayer 走私有框架 _AVKit_SwiftUI，在某些系统版本上实例化即崩溃。
struct PlayerViewRepresentable: NSViewRepresentable {
    let player: AVPlayer
    /// 烧字幕预览给 `.none`：自带的控件浮在画面底部，正好压住字幕，
    /// 那一块恰恰是要看的地方，所以那边自己画播放条。
    var controlsStyle: AVPlayerViewControlsStyle = .inline

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
    }
}

