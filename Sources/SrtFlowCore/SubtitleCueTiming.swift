import Foundation

// 生成的字幕什么时候出、什么时候收（2026-09-26 按主流规范定，docs/architecture/subtitle-generation-style.md）。
//
// 管什么（对整条字幕轨一起算，不分是哪段素材来的）：
// - 说完之后多停半秒（后面没有紧跟着的下一条时），但至少显示 5/6 秒；
// - 两条之间至少留 2 帧，观众才看得出换了一条；空档不到半秒就把前一条延过去、只剩 2 帧，
//   不让字幕闪一下 —— 两条之间要么只差 2 帧，要么至少半秒（Netflix 的「chaining」）；
// - 最晚收在它那段素材在时间线上的结尾（素材切走了，字幕不跟过去）；
// - 阅读速度超了如实告警（按最终显示时长算）。
// 不管什么：字切成几条（`SubtitleBreaks`）、几段素材同时有字时留谁（`SubtitleSourceOverlap`）。

public enum SubtitleCueTiming {

    /// 排好每条的结束时间。
    /// - Parameters:
    ///   - cues: 按开始时间排好、互不重叠的字幕（开始 = 第一个词开口，结束 = 最后一个词说完）。
    ///   - limits: 每条最晚收到哪（它那段素材在时间线上的结尾）；没有就不限。
    public static func apply(
        to cues: inout [SubtitleCue], limits: [UUID: Double], config: SubtitleSegmentationConfig
    ) {
        let gap = config.gap
        for index in cues.indices {
            let start = cues[index].start
            let next = index + 1 < cues.count ? cues[index + 1].start : Double.infinity
            var end = max(cues[index].end + config.trailingHold, start + config.minCueDuration)
            if next - end < config.chainThreshold { end = next - gap }
            end = min(end, limits[cues[index].id] ?? .infinity)
            // 下一条几乎同时开始（不该发生：同一段素材的字前后相接，几段素材之间先去过重叠）：至少留一帧。
            cues[index].end = max(end, start + config.frameDuration)
        }
    }

    /// 按最终显示时长标阅读速度告警（字数按 `SubtitleLineMeasure.units`）。
    public static func markReadingSpeed(
        _ cues: [SubtitleCue], meta: inout [UUID: CueMeta], config: SubtitleSegmentationConfig
    ) {
        for cue in cues where meta[cue.id] != nil {
            let speed = SubtitleLineMeasure.units(cue.text) / max(cue.duration, 0.001)
            meta[cue.id]?.readingSpeedWarning = speed > config.maxUnitsPerSecond + 1e-9
        }
    }
}
