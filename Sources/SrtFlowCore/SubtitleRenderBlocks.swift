import Foundation

// MARK: - 画面上的字幕块：此刻显示什么、按时间怎么切
//
// 管什么：一块字幕（共用一个布局的几层句子，比如叠在一起的原文 + 译文）在某一刻显示哪几行、哪个词正在说
// （逐词高亮），以及烧录时怎么把它切成一段段互不重叠的事件。**预览和烧录只认这里**：预览每一刻调 `display(at:)`，
// 烧录调 `timeline(_:)`，而每一段的样子就是段起点那一刻的 `display(at:)` —— 两边同一个函数，看到的就是成片。
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
    /// 写进 ASS 的事件。视频编辑器传进来的是切好的段（`SubtitleTimeSlicing.timeline`）。
    public var cues: [SubtitleCue]
    /// nil = 全局烧录样式原样。
    public var layout: SubtitleLayout?
    /// 逐词高亮（nil = 不高亮）和每段事件里此刻正在说的词（事件 ID → 在事件字里的位置）。
    public var highlight: SubtitleWordHighlight?
    public var highlights: [UUID: [SubtitleTextRange]]

    public init(
        cues: [SubtitleCue], layout: SubtitleLayout?,
        highlight: SubtitleWordHighlight? = nil, highlights: [UUID: [SubtitleTextRange]] = [:]
    ) {
        self.cues = cues
        self.layout = layout
        self.highlight = highlight
        self.highlights = highlights
    }

    /// 视频编辑器的一块：几层句子按时间切好，`highlight` 不为 nil 时每段带上此刻正在说的词。
    public init(layers: [[SubtitleCue]], layout: SubtitleLayout?, highlight: SubtitleWordHighlight?) {
        var cues: [SubtitleCue] = []
        var highlights: [UUID: [SubtitleTextRange]] = [:]
        for (index, slice) in SubtitleTimeSlicing.timeline(layers, highlighting: highlight != nil).enumerated() {
            let cue = SubtitleCue(index: index + 1, start: slice.start, end: slice.end, text: slice.display.text)
            if !slice.display.highlights.isEmpty { highlights[cue.id] = slice.display.highlights }
            cues.append(cue)
        }
        self.init(cues: cues, layout: layout, highlight: highlight, highlights: highlights)
    }
}

/// 某一刻一块字幕显示的样子：字，和其中正在说的词（逐词高亮打开、这句有词的时间时才有）。
public struct SubtitleDisplay: Hashable, Sendable {
    public var text: String
    public var highlights: [SubtitleTextRange]

    public init(text: String, highlights: [SubtitleTextRange] = []) {
        self.text = text
        self.highlights = highlights
    }
}

/// 烧录的一段：这段时间里屏上显示的样子不变。
public struct SubtitleSlice: Hashable, Sendable {
    public var start: Double
    public var end: Double
    public var display: SubtitleDisplay
}

public enum SubtitleTimeSlicing {

    /// 这一刻这块字幕显示的字：各层此刻在屏上的句子，**排在前面的层在上面**；同一层里重叠的几句，
    /// 顺序排在前面的在最下面（与以前 libass 叠重叠事件的方向一致：先来的在底下）。
    /// 一个字都没有就是 nil。
    public static func text(at time: Double, layers: [[SubtitleCue]]) -> String? {
        display(at: time, layers: layers)?.text
    }

    /// 同上，`highlighting` 时再带上此刻正在说的词在字里的位置（`SubtitleCueWords.activeRange`）。
    /// 预览每一刻画它，烧录每一段的样子也是它给的（`timeline`）。
    public static func display(at time: Double, layers: [[SubtitleCue]], highlighting: Bool = false) -> SubtitleDisplay? {
        var text = ""
        var highlights: [SubtitleTextRange] = []
        for layer in layers {
            for cue in SubtitleOverlap.active(at: time, in: layer).reversed() {
                let plain = SubtitleSerializer.plainText(cue.text)
                guard !plain.isEmpty else { continue }
                if !text.isEmpty { text += "\n" }
                if highlighting, let range = SubtitleCueWords.activeRange(of: cue, at: time) {
                    highlights.append(SubtitleTextRange(location: text.utf16.count + range.location, length: range.length))
                }
                text += plain
            }
        }
        return text.isEmpty ? nil : SubtitleDisplay(text: text, highlights: highlights)
    }

    /// 按「此刻屏上是什么样」切成互不重叠的段：每段的样子 = 段起点那一刻的 `display`，首尾相接、样子一样的
    /// 相邻两段并成一段；没有字的时间不出段。`highlighting` 时每个词开口、最后一个词说完也切一刀。
    public static func timeline(_ layers: [[SubtitleCue]], highlighting: Bool = false) -> [SubtitleSlice] {
        var bounds = Set(layers.flatMap { layer in layer.flatMap { [$0.start, $0.end] } })
        if highlighting {
            for layer in layers { for cue in layer { bounds.formUnion(SubtitleCueWords.changeTimes(of: cue)) } }
        }
        let sorted = bounds.sorted()
        var result: [SubtitleSlice] = []
        for (start, end) in zip(sorted, sorted.dropFirst()) where end > start {
            guard let display = display(at: start, layers: layers, highlighting: highlighting) else { continue }
            if let last = result.last, last.end == start, last.display == display {
                result[result.count - 1].end = end
            } else {
                result.append(SubtitleSlice(start: start, end: end, display: display))
            }
        }
        return result
    }

    /// 不高亮时的段，写成 ASS 事件（字就是段的字）。
    public static func slices(_ layers: [[SubtitleCue]]) -> [SubtitleCue] {
        timeline(layers).enumerated().map { index, slice in
            SubtitleCue(index: index + 1, start: slice.start, end: slice.end, text: slice.display.text)
        }
    }
}
