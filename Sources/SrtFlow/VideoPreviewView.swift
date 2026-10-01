import SwiftUI
import AVFoundation
import Combine
import SrtFlowCore

/// Owns the AVPlayer and publishes playback time for subtitle sync.
///
/// **只有真跟着播放头动的小视图才许订阅它**（播放头的线、时间读数、预览上的叠层、电平表）：
/// 播放时它一秒发二十次，订阅它的大视图就一秒重算二十次。检查器、素材库那一栏读
/// `whilePaused` / `atRest`（`PacedPlayhead`）；按钮能不能点看播放头的，用
/// `.disabled(followingPlayhead:)`（docs/architecture/preview-perf-ratchet.md 第十二节）。
final class PlayerClock: ObservableObject {
    @Published private(set) var time: TimeInterval = 0
    @Published private(set) var hasVideo = false
    @Published private(set) var isPlaying = false
    /// 悬停预览（peek）此刻指着哪：非 nil 时画面显示的是这里的帧，而 `time`
    /// （真播放头）原地不动。时间线用它画那根半透明的影子指针。
    @Published private(set) var peekTime: TimeInterval?

    /// 播放头被放到了哪儿（`seek`、换片、卸片）。播放把它带着走的时间回调不发这里。
    let placed = PassthroughSubject<PlayheadPlacement, Never>()
    /// 播放头被「回到开头」（Return / Home，2026-09-26 用户拍板）送到了 0：时间线要滚回最左、露出它。
    /// **和 `placed` 分开**：重建预览之后调用方会 seek 回原位，那一下也发 `placed` —— 拿它来滚时间线的话，
    /// 每改一刀时间线都会被拽回播放头。只有用户明确要「回到开头」时才发这里。
    let wentToStart = PassthroughSubject<Void, Never>()
    /// 播放头的两种慢读法（见 `PacedPlayhead`）。懒建：烧字幕页的时钟用不上，不必挂订阅。
    lazy var whilePaused = PacedPlayhead(clock: self, pace: .whilePaused)
    lazy var atRest = PacedPlayhead(clock: self, pace: .atRest)

    /// 预览画面此刻实际显示的时间：悬停预览优先，否则就是播放头。
    /// 叠在画面上的东西（字幕、形状、变换框）读这个才和帧对得上。
    var displayTime: TimeInterval { peekTime ?? time }

    let player = AVPlayer()
    /// 时间回调的间隔（init 时定）：`estimatedTime` 最多往前补这么长。
    let observationInterval: TimeInterval
    /// 最近一次时间回调落地（或 seek）时的 host 时间，给 `estimatedTime` 外推用。主线程读写。
    private var tickHostTime: TimeInterval = 0
    private var timeObserver: Any?
    private var rateObservation: NSKeyValueObservation?

    /// 链式 seek（Apple QA1820）的两个状态：上一个 seek 还没完成时只记下最新目标，
    /// 完成后再续发。主线程读写。
    private var isScrubSeeking = false
    private var pendingScrubTarget: TimeInterval?

    /// 声音引擎（开关开着时由工程挂上，见 PreviewAudioEngineHost）。挂着时它是主时钟：`time` 每 50 ms 从它读一次，
    /// 播放器的周期回调只用来对表（差过一帧就把视频重新钉到引擎的时间表上）。
    private(set) var audioSource: PlaybackAudioSource?
    private var audioTimer: Timer?
    /// 视频和引擎连续几拍对不上（一拍的偶差不管，连着两拍才对表）。
    private var driftTicks = 0
    /// 对了几次表（冒烟看它）。
    private(set) var driftCorrections = 0
    /// 上一次往卡顿日志里记「对表」的时刻：连着对表只记第一次，别把日志淹了。
    private var lastDriftNote: TimeInterval = 0

    /// - Parameter observationInterval: 时间回调的间隔。烧字幕预览要靠它切换叠在
    ///   画面上的那句字幕，所以给得比字幕编辑器密一些。
    init(observationInterval: TimeInterval = 0.25) {
        self.observationInterval = observationInterval
        // GUI 冒烟的静音钩子：验播放时别往正在用机器的人耳朵里外放。
        // 环境变量不设就完全不生效（docs/testing/gui-smoke-testing.md）。
        if ProcessInfo.processInfo.environment["SRTFLOW_SMOKE_MUTE"] != nil { player.volume = 0 }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: observationInterval, preferredTimescale: 600),
            queue: .main
        ) { [weak self] cmTime in
            // 卸了片（detach）之后还会晚到一拍、报旧条目的时间：新建 / 打开工程先卸片、播放头归零，这一拍把它写回
            // 上一个工程的位置（2026-09-29，docs/bugfixes/2026-09-29-new-project-keeps-old-playhead.md）。没有条目就没有播放时间。
            guard let clock = self, clock.player.currentItem != nil else { return }
            if clock.audioSource != nil {
                // 引擎驱动：播放头从引擎读（attachAudioSource 的 timer），这一拍只用来对表。
                clock.checkVideoDrift(videoTime: cmTime.seconds)
            } else {
                self?.observePlaybackTime(cmTime.seconds)
            }
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

    /// 播放器报来一次播放时间（播放时每 `observationInterval` 一次）。
    ///
    /// 单独成一个方法是为了性能测试：它的「时钟连跳」要走和真播放**同一段**
    /// 代码（PreviewBench.swift），不能另写一份直接改 `time`。
    func observePlaybackTime(_ seconds: TimeInterval) {
        PerfCounters.event(.clockTick)
        // 悬停预览期间播放器在别处扫帧，这些回调不能写回播放头 ——
        // 否则播放头还是会被悬停拖走，peek 就白做了。
        if peekTime == nil {
            time = seconds
            tickHostTime = ProcessInfo.processInfo.systemUptime
        }
    }

    /// 播放头此刻大概在哪，**不问播放器**：最近一跳的时间，加上从那一跳到现在过了多久（最多补一跳）。
    ///
    /// 跟着播放头画东西的高频读者（电平条：每条轨每秒 30 次）读它。`player.currentTime()` 要拿播放器
    /// 内部那把锁，播放器自己的队列一忙（多轨合成的音频管线在干活）主线程就被堵住 —— 2026-10-01 在
    /// 南极工程里抓到一次 2.4 秒、几次 200–300 ms，空格按下去图标慢半拍就是它
    /// （docs/bugfixes/2026-10-01-meter-current-time-blocks-main-thread.md）。`checks/player-time-no-sync-read.sh`
    /// 钉着：App 代码里不许再出现 `currentTime()`，时间只从时钟的回调来。
    var estimatedTime: TimeInterval {
        PlaybackTimeEstimate.estimate(
            tick: time, tickHost: tickHostTime, now: ProcessInfo.processInfo.systemUptime,
            isPlaying: isPlaying, maxLead: observationInterval
        )
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        rateObservation?.invalidate()
        audioTimer?.invalidate()
        // 视图被销毁（比如切走了侧边栏那一栏）时别让声音还在响。
        player.pause()
    }

    // MARK: 声音引擎当主时钟

    /// 挂上引擎：从此播放头从它读、视频跟着它。只挂一次。
    func attachAudioSource(_ source: PlaybackAudioSource) {
        guard audioSource == nil else { return }
        audioSource = source
        // `setRate(_:time:atHostTime:)` 要求关掉「等缓冲」（开着会抛异常）；本地文件本来也不用等。
        player.automaticallyWaitsToMinimizeStalling = false
        let timer = Timer(timeInterval: observationInterval, repeats: true) { [weak self] _ in
            guard let self, let source = audioSource, source.isPlaying else { return }
            observePlaybackTime(source.playhead)
        }
        RunLoop.main.add(timer, forMode: .common)
        audioTimer = timer
    }

    /// 视频的周期回调报来的时间和引擎差过一帧（连着两拍）就把视频重新钉到引擎的时间表上。
    private func checkVideoDrift(videoTime: TimeInterval) {
        guard let source = audioSource, source.isPlaying, player.rate > 0 else {
            driftTicks = 0
            return
        }
        let drift = abs(videoTime - source.playhead)
        guard drift > 0.04 else {
            driftTicks = 0
            return
        }
        driftTicks += 1
        guard driftTicks >= 2 else { return }
        driftTicks = 0
        driftCorrections += 1
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastDriftNote > 1 {
            lastDriftNote = now
            MainThreadWatchdog.shared.note(String(format: "视频对表：画面 %.3f s、引擎 %.3f s（差 %.0f ms），重新钉到引擎", videoTime, source.playhead, drift * 1000))
        }
        anchorVideo(to: source.playhead)
    }

    /// 让视频从 `seconds` 起、从**此刻**开始跟着走：播放器自己去定位，定位要多久就晚多久赶上来，不改时间表。
    private func anchorVideo(to seconds: TimeInterval) {
        player.setRate(1, time: CMTime(seconds: seconds, preferredTimescale: 600), atHostTime: CMClockGetTime(CMClockGetHostTimeClock()))
    }

    /// 开播（空格、重建之后接着播）：引擎驱动时声音先起、视频钉到同一个时刻；否则就是播放器自己播。
    func play() {
        if let source = audioSource {
            source.play(from: time)
            anchorVideo(to: time)
        } else {
            player.play()
        }
    }

    func attach(url: URL, autoplay: Bool = true) {
        pendingScrubTarget = nil
        peekTime = nil
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        hasVideo = true
        time = 0
        placed.send(PlayheadPlacement(time: 0, precise: true))
        if autoplay { player.play() }
    }

    /// 换上一个现成的条目（时间线合成不是 URL，`attach(url:)` 用不上）。
    /// 播放头交给调用方自己恢复。
    func attachItem(_ item: AVPlayerItem) {
        PerfCounters.event(.playerItemAttach)
        pendingScrubTarget = nil
        peekTime = nil
        player.replaceCurrentItem(with: item)
        hasVideo = true
    }

    func detach() {
        audioSource?.pause()
        audioSource?.seek(to: 0)
        player.pause()
        player.replaceCurrentItem(with: nil)
        pendingScrubTarget = nil
        peekTime = nil
        hasVideo = false
        time = 0
        placed.send(PlayheadPlacement(time: 0, precise: true))
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
        tickHostTime = ProcessInfo.processInfo.systemUptime
        placed.send(PlayheadPlacement(time: clamped, precise: precise))
        if let source = audioSource {
            // 引擎驱动：声音先跳过去（一个 IO 缓冲就出声）；视频在播就钉到同一个时刻（播放器自己定位、赶上来），
            // 停着就照旧精确定位 / 链式扫帧。
            source.seek(to: clamped)
            if player.rate > 0 {
                pendingScrubTarget = nil
                MainThreadWatchdog.shared.note(String(format: "播放中 seek → %.3f s（引擎先跳，视频钉过去自己赶）", clamped))
                anchorVideo(to: clamped)
                return
            }
        }
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

    /// Return / Home：播放头回到开头。正在播就从开头接着播（`seek` 不改播放状态），停着就停在 0，
    /// 再按空格从头播。时间线听 `wentToStart` 滚回最左。
    func goToStart() {
        seek(to: 0)
        wentToStart.send()
    }

    func togglePlayback() {
        if player.rate > 0 {
            pause()
        } else {
            // 悬停预览把画面带去了别处：播放必须从**播放头**起，先precise跳回去。
            // seek 后紧跟 play 是安全的（play 不取消在飞的 seek，完成后从目标续播）。
            // 引擎驱动时不用：`play()` 里的 setRate 自带定位。
            if peekTime != nil {
                peekTime = nil
                pendingScrubTarget = nil
                if audioSource == nil {
                    player.seek(
                        to: CMTime(seconds: time, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero
                    )
                }
            }
            play()
        }
    }

    func pause() {
        audioSource?.pause()
        player.pause()
    }
}

// MARK: - 播放头的外推（纯值）

/// `PlayerClock.estimatedTime` 的算术：最近一跳 `tick` 是在 host 时间 `tickHost` 落地的，现在是 `now`。
/// 播放中就把过去的这段时间补上，但最多补 `maxLead`（时钟的回调间隔）—— 回调要是晚到了，外推不许
/// 一直往前跑；停着就是 `tick` 本身。`now` 比 `tickHost` 还早（时钟倒退）按没过时间算。
enum PlaybackTimeEstimate {
    static func estimate(tick: TimeInterval, tickHost: TimeInterval, now: TimeInterval,
                         isPlaying: Bool, maxLead: TimeInterval) -> TimeInterval {
        guard isPlaying, tickHost > 0 else { return tick }
        let elapsed = min(max(0, now - tickHost), max(0, maxLead))
        return tick + elapsed
    }
}
