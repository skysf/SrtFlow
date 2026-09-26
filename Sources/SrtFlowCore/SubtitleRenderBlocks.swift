import Foundation

// MARK: - 画面上的字幕块：此刻显示什么、按时间怎么切
//
// 管什么：一块字幕（共用一个布局的几层句子，比如叠在一起的原文 + 译文）在某一刻显示哪几行、
// 以及烧录时怎么把它切成一段段互不重叠的事件。**预览和烧录只认这里**：预览每一刻调 `text(at:)`，
// 烧录调 `slices(_:)`，而每一段的字就是段起点那一刻的 `text(at:)` —— 两边同一个函数，看到的就是成片。
// 不管什么：哪几层进哪一块、块用哪个布局（视频编辑器的 `TimelineState.subtitleRenderBlocks`）、
// 怎么写成 ASS（`BurnInStyle.assDocument(blocks:)`）。
//
// 为什么要切（2026-09-26，docs/plans/2026-09-26-hide-guides-independent-subtitles.md S10/S11）：
// 原文、译文拆成两条独立轨之后起止不再对齐。叠在一起显示时，原文一句可能横跨两句译文 —— 不切的话
// 烧录没法把两句排成一块（libass 按事件开始的先后往上叠，谁在上面会中途对调）。切成段之后每段一个事件，
// 原文行永远在上、译文行永远在下，一句换行变高另一句自然让开。同一层里重叠的几句也并进同一段
// （以前各自一个事件、靠 libass 往上叠；预览本来就是把它们拼成一块画的）。

/// 画面上的一块字幕：几层句子排在一起、共用一个布局。
public struct SubtitleRenderBlock: Hashable, Sendable {
    /// 写进 ASS 的事件。视频编辑器传进来的是切好的段（`SubtitleTimeSlicing.slices`）。
    public var cues: [SubtitleCue]
    /// nil = 全局烧录样式原样。
    public var layout: SubtitleLayout?

    public init(cues: [SubtitleCue], layout: SubtitleLayout?) {
        self.cues = cues
        self.layout = layout
    }
}

public enum SubtitleTimeSlicing {

    /// 这一刻这块字幕显示的字：各层此刻在屏上的句子，**排在前面的层在上面**；同一层里重叠的几句，
    /// 顺序排在前面的在最下面（与以前 libass 叠重叠事件的方向一致：先来的在底下）。
    /// 一个字都没有就是 nil。
    public static func text(at time: Double, layers: [[SubtitleCue]]) -> String? {
        let parts = layers.map { layer in
            SubtitleOverlap.active(at: time, in: layer).reversed()
                .map { SubtitleSerializer.plainText($0.text) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// 按「此刻谁在屏上」切成互不重叠的段：每段的字 = 段起点那一刻的 `text(at:layers:)`，
    /// 首尾相接、字一样的相邻两段并成一段；没有字的时间不出段。
    public static func slices(_ layers: [[SubtitleCue]]) -> [SubtitleCue] {
        let bounds = Set(layers.flatMap { layer in layer.flatMap { [$0.start, $0.end] } }).sorted()
        var result: [SubtitleCue] = []
        for (start, end) in zip(bounds, bounds.dropFirst()) where end > start {
            guard let text = text(at: start, layers: layers) else { continue }
            if let last = result.last, last.end == start, last.text == text {
                result[result.count - 1].end = end
            } else {
                result.append(SubtitleCue(start: start, end: end, text: text))
            }
        }
        for i in result.indices { result[i].index = i + 1 }
        return result
    }
}
