import SwiftUI
import AVKit
import SrtFlowCore

/// Owns the AVPlayer and publishes playback time for subtitle sync.
final class PlayerClock: ObservableObject {
    @Published private(set) var time: TimeInterval = 0
    @Published private(set) var hasVideo = false
    @Published private(set) var isPlaying = false
    /// 悬停预览（peek）此刻指着哪：非 nil 时画面显示的是这里的帧，而 `time`
    /// （真播放头）原地不动。时间线用它画那根半透明的影子指针。
    @Published private(set) var peekTime: TimeInterval?

    /// 预览画面此刻实际显示的时间：悬停预览优先，否则就是播放头。
    /// 叠在画面上的东西（字幕、形状、变换框）读这个才和帧对得上。
    var displayTime: TimeInterval { peekTime ?? time }

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
            guard let self else { return }
            // 悬停预览期间播放器在别处扫帧，这些回调不能写回播放头 ——
            // 否则播放头还是会被悬停拖走，peek 就白做了。
            if self.peekTime == nil { self.time = cmTime.seconds }
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
        peekTime = nil
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        hasVideo = true
        time = 0
        if autoplay { player.play() }
    }

    /// 换上一个现成的条目（时间线合成不是 URL，`attach(url:)` 用不上）。
    /// 播放头交给调用方自己恢复。
    func attachItem(_ item: AVPlayerItem) {
        pendingScrubTarget = nil
        peekTime = nil
        player.replaceCurrentItem(with: item)
        hasVideo = true
    }

    func detach() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        pendingScrubTarget = nil
        peekTime = nil
        hasVideo = false
        time = 0
    }

    /// - Parameter precise: 松手和按字幕跳转时给 `true`（立刻精确定位）；拖动/悬停
    ///   扫过的过程中给 `false` —— 也是零容差逐帧刷新，但走链式 seek 防洪。
    ///   注意不能退回「就近关键帧」的粗定位：合成条目的关键帧隔好几秒一个，
    ///   拖动中画面会看起来纹丝不动（docs/bugfixes/2026-08-03-scrub-preview-keyframe-snap.md）。
    func seek(to seconds: TimeInterval, precise: Bool = true) {
        // 任何真正的定位（点标尺、拖播放头、点字幕……）都终结悬停预览：
        // 播放头就该移过去，影子指针消失。
        peekTime = nil
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

    // MARK: 悬停预览（peek）

    /// 画面滚到指的那一帧看一眼，但**不动播放头**。走链式 seek 防洪，
    /// 和拖动扫帧同一条路（docs/bugfixes/2026-08-03-scrub-preview-keyframe-snap.md）。
    func peek(at seconds: TimeInterval) {
        let clamped = max(0, seconds)
        peekTime = clamped
        scrub(to: clamped)
    }

    /// 悬停结束：影子指针消失，画面滚回播放头。没在 peek 时是无害的 no-op。
    func endPeek() {
        guard peekTime != nil else { return }
        peekTime = nil
        scrub(to: time)
    }

    func togglePlayback() {
        if player.rate > 0 {
            player.pause()
        } else {
            // 悬停预览把画面带去了别处：播放必须从**播放头**起，先precise跳回去。
            // seek 后紧跟 play 是安全的（play 不取消在飞的 seek，完成后从目标续播）。
            if peekTime != nil {
                peekTime = nil
                pendingScrubTarget = nil
                player.seek(
                    to: CMTime(seconds: time, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero
                )
            }
            player.play()
        }
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

