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
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        hasVideo = true
        time = 0
        if autoplay { player.play() }
    }

    /// 换上一个现成的条目（时间线合成不是 URL，`attach(url:)` 用不上）。
    /// 播放头交给调用方自己恢复。
    func attachItem(_ item: AVPlayerItem) {
        player.replaceCurrentItem(with: item)
        hasVideo = true
    }

    func detach() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        hasVideo = false
        time = 0
    }

    /// - Parameter precise: 拖进度条的过程中给 `false`（跳到最近的关键帧，跟手），
    ///   松手和按字幕跳转时要 `true` —— 核对字幕时间轴差半秒都算错。
    func seek(to seconds: TimeInterval, precise: Bool = true) {
        let clamped = max(0, seconds)
        let target = CMTime(seconds: clamped, preferredTimescale: 600)
        if precise {
            player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            player.seek(to: target)
        }
        time = clamped
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

