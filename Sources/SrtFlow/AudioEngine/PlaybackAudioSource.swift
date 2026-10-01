import Foundation

// MARK: - 声音引擎在时钟眼里的样子
//
// 管什么：`PlayerClock` 驱动引擎只经这几个方法（`TimelineAudioEngine` 实现它）。单独一个文件、不依赖任何东西：
// 时钟的自检（check-player-clock.sh）只编这一个小文件，不必把整个引擎编进去。
// 挂上它之后**声音是主时钟**：播放头从它读，视频用 `setRate(_:time:atHostTime:)` 钉到它的时间表上
// （docs/architecture/audio-engine.md）。

protocol PlaybackAudioSource: AnyObject {
    /// 此刻播放头在时间线的第几秒。
    var playhead: Double { get }
    var isPlaying: Bool { get }
    func play(from seconds: Double)
    func pause()
    func seek(to seconds: Double)
}
