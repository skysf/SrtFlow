import AVFoundation
import Combine
import Foundation

// MARK: - 对比窗口的两个播放器：原片和 upscale 文件同步播
//
// 管什么：两个 AVPlayer（原片那一段出声，upscale 文件静音）、同一个主机时间起步（`setRate(_:time:atHostTime:)`，不读 `currentTime`：
// checks/player-time-no-sync-read.sh 禁的那种同步读），seek 两边一起、循环、每 1/30 秒报一次时间（周期观察器，不是同步读）。
// 原片的 0 秒不是对比的 0 秒：原片要加上 `offset`（新文件的 0 秒 = 原片的第几秒）。
// 不管什么：画面怎么摆、分割线（UpscaleCompareStage）、按钮（UpscaleCompareView）。

@MainActor
final class UpscaleComparePlayback: ObservableObject {
    let original = AVPlayer()
    let upscaled = AVPlayer()
    let offset: Double
    @Published private(set) var time: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying = false
    @Published var loops = true

    private var observer: Any?
    private var endObserver: NSObjectProtocol?
    private var cancellables: Set<AnyCancellable> = []

    init(originalURL: URL, upscaledURL: URL, offset: Double) {
        self.offset = offset
        original.automaticallyWaitsToMinimizeStalling = false
        upscaled.automaticallyWaitsToMinimizeStalling = false
        upscaled.isMuted = true
        let upscaledItem = AVPlayerItem(url: upscaledURL)
        upscaled.replaceCurrentItem(with: upscaledItem)
        original.replaceCurrentItem(with: AVPlayerItem(url: originalURL))
        observer = upscaled.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] now in
            Task { @MainActor in self?.time = max(0, now.seconds) }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: upscaledItem, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reachedEnd() }
        }
        upscaledItem.publisher(for: \.status).receive(on: DispatchQueue.main).sink { [weak self] status in
            guard status == .readyToPlay, let self else { return }
            self.duration = upscaledItem.duration.seconds.isFinite ? upscaledItem.duration.seconds : 0
        }.store(in: &cancellables)
        seek(to: 0)
    }

    deinit {
        if let observer { upscaled.removeTimeObserver(observer) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    func togglePlay() {
        if isPlaying { pause() } else { play(from: time) }
    }

    func pause() {
        original.pause()
        upscaled.pause()
        isPlaying = false
    }

    /// 两边同一个主机时间起步：原片从 `offset + t`，upscale 文件从 `t`。
    func play(from t: Double) {
        let host = CMClockGetTime(CMClockGetHostTimeClock())
        original.setRate(1, time: CMTime(seconds: offset + t, preferredTimescale: 600), atHostTime: host)
        upscaled.setRate(1, time: CMTime(seconds: t, preferredTimescale: 600), atHostTime: host)
        isPlaying = true
    }

    func seek(to t: Double) {
        let wasPlaying = isPlaying
        pause()
        let target = max(0, t)
        original.seek(to: CMTime(seconds: offset + target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        upscaled.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        time = target
        if wasPlaying { play(from: target) }
    }

    private func reachedEnd() {
        if loops {
            seek(to: 0)
            play(from: 0)
        } else {
            pause()
        }
    }
}
