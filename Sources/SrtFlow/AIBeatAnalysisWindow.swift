import Foundation

// MARK: - 鼓点分析哪一段：整首歌
//
// 管什么：listen 的 beats 和 cut_to_beat 问某个文件某一段的鼓点时，真正拿去分析的是哪一段（纯值）。拍子是整首歌的事：
// 请求落在文件开头 15 分钟里就分析**整段**（到文件结尾或 15 分钟），两边再各按自己的区间挑拍 —— 看的是同一份分析。
// 以前按请求的区间分析：listen 看 0–90 秒、cut_to_beat 看片段用到的 0–32 秒，同一首《Perfect》一边 63.5 BPM 一边 95.3
// （3:2，6/8 拍的两种数法），切点比重拍晚 0.25 秒（2026-09-29 婚礼工程 BUG-07，
// docs/bugfixes/2026-09-29-beat-analysis-window-differs-between-listen-and-cut-to-beat.md）。超出 15 分钟的请求才按它自己的区间。
// 不管什么：读采样、缓存、算拍子（AIBeats / AudioBeatTracker）。

enum BeatAnalysisWindow {
    /// 一次最多分析多长（秒）：15 分钟的单声道 11025 Hz 约 40MB。
    static let maxSeconds = 900.0

    static func resolve(from: Double, to: Double, fileDuration: Double) -> (from: Double, to: Double) {
        let wholeEnd = min(max(fileDuration, 0), maxSeconds)
        if to <= wholeEnd + 0.001 { return (0, wholeEnd) }
        return (from, min(to, from + maxSeconds))
    }
}
