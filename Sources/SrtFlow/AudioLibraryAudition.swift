import AVFoundation
import Combine
import Foundation

// 音频库的试听。产品口径见 docs/plans/2026-09-22-audio-library.md 第六节。
//
// 三条口径，都是用户拍的板：
//
// 1. **不暂停时间线。** 视频照播，试听的声音叠上去 —— 挑配乐本来就是要听它
//    配在这段画面上是什么样，停下来听等于什么都没验。
// 2. **时间线自动让路 −12dB**，试听停了恢复。两路声音原样叠在一起谁都听不清。
// 3. **流播，不落盘**（`AVPlayer` 直接吃 manifest 给的 URL）。翻库听十首只为挑
//    一首，没道理先把十首都存下来 —— 拖进时间线那一刻才真下载。
//
// **ducking 压的是 `AVPlayer.volume`，绝不是 `audioMix`。**
// `audioMix` 是工程数据算出来的东西（每段的音量、渐入渐出，唯一夹紧点在
// `AudioGain` / `VideoEditAudioFade`）—— 为了试听去改它，等于把用户调好的音量
// 写脏，还会触发一次预览重建。`AVPlayer.volume` 是播放器的输出增益，
// 和工程数据不相干，压完恢复不留痕迹。

@MainActor
final class AudioLibraryAudition: ObservableObject {
    static let shared = AudioLibraryAudition()

    /// 正在试听的素材 id；没有就是 nil。
    @Published private(set) var playingID: String?
    /// 0…1。
    @Published private(set) var progress: Double = 0
    /// 正在缓冲（点了还没出声）。
    @Published private(set) var isBuffering = false

    /// 试听时把时间线压低多少。
    static let duckingDB = -12.0

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    /// 压低之前时间线播放器的音量，停止时原样还回去 —— 不是硬写 1.0，
    /// 万一别处也在调它，硬写会把那边的设定抹掉。
    private var restoreVolume: Float?

    private init() {}

    // MARK: - 播 / 停

    /// 点一下：正在听这首就停，否则换成这首。
    func toggle(_ item: AudioLibraryItem, timelinePlayer: AVPlayer?) {
        if playingID == item.id {
            stop(timelinePlayer: timelinePlayer)
        } else {
            play(item, timelinePlayer: timelinePlayer)
        }
    }

    func play(_ item: AudioLibraryItem, timelinePlayer: AVPlayer?) {
        teardown()

        // 已经下过就放本地的：起播快，而且断网照样能听。
        let url = AudioLibraryCache.shared.localURL(for: item.id) ?? item.url
        let player = AVPlayer(url: url)
        player.volume = 1
        self.player = player
        playingID = item.id
        progress = 0
        isBuffering = true

        duck(timelinePlayer)

        statusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            Task { @MainActor in
                self?.isBuffering = p.timeControlStatus == .waitingToPlayAtSpecifiedRate
            }
        }
        let interval = CMTime(seconds: 0.2, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] t in
            Task { @MainActor in
                guard let self, item.duration > 0 else { return }
                self.progress = min(1, max(0, t.seconds / item.duration))
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.stop(timelinePlayer: timelinePlayer) }
        }
        player.play()
    }

    func stop(timelinePlayer: AVPlayer?) {
        teardown()
        unduck(timelinePlayer)
        playingID = nil
        progress = 0
        isBuffering = false
    }

    // MARK: - 让路

    private func duck(_ timeline: AVPlayer?) {
        guard let timeline else { return }
        // 已经压过就不再记一次：连点两首的话第二次会把"原值"记成压低后的值，
        // 松手之后时间线就永远留在 −12dB 上了。
        if restoreVolume == nil { restoreVolume = timeline.volume }
        let factor = Float(pow(10.0, Self.duckingDB / 20.0))
        timeline.volume = (restoreVolume ?? 1) * factor
    }

    private func unduck(_ timeline: AVPlayer?) {
        guard let timeline, let restore = restoreVolume else { return }
        timeline.volume = restore
        restoreVolume = nil
    }

    private func teardown() {
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObservation?.invalidate()
        statusObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player?.pause()
        player = nil
    }
}
