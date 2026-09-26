import Foundation
import SrtFlowCore

// MARK: - 两条字幕轨在时间线上的读法，以及画面上排成几块
//
// 管什么：原文 / 译文两条轨的句子怎么找（按 ID、按轨）、哪条轨藏着、导出字幕文件用哪份文档，
// 以及**预览和烧录共用的**「看得见的字幕排成几块、每块用哪个布局」（`subtitleScreenBlocks`）。
// 不管什么：怎么改（SrtFlowCore 的 `SubtitleTrackEditing`，工程层入口在 VideoEditProjectSubtitleLink.swift）、
// 一块在某一刻显示什么 / 怎么按时间切（SrtFlowCore 的 `SubtitleTimeSlicing`）。
// checks/ProjectFile 把本文件编进自检。
//
// 2026-09-26 两条轨独立之后（docs/plans/2026-09-26-hide-guides-independent-subtitles.md S7/S10）：
// 译文轨的布局为 nil = 叠在原文下面，和原文排成**一块**（原文在上、译文在下，一句换行变高另一句自然让开）；
// 有值 = 各自一块、各摆各的。老工程（只有 `subtitleLayout`、双语排成一块）不用迁移、成片一模一样。

/// 画面上的一块字幕：预览画一块，烧录写一个 ASS 样式。
struct SubtitleScreenBlock: Equatable {
    /// 这一块里有哪几条轨，**从上到下**。叠在一起时是 [原文, 译文]。
    var tracks: [SubtitleTrack]
    /// 每条轨在这一块里显示的句子（已按重叠合同排好序），与 `tracks` 一一对应。
    var layers: [[SubtitleCue]]
    /// nil = 全局烧录样式原样。
    var layout: SubtitleLayout?

    var isStacked: Bool { tracks.count > 1 }

    /// 这一刻这一块显示的字（预览）。烧录每一段的字也是这个函数给的（`renderBlock`）。
    func text(at time: Double) -> String? {
        SubtitleTimeSlicing.text(at: time, layers: layers)
    }

    /// 这一刻这一块里某条轨在屏上的句子（合同序）。
    func activeCues(of track: SubtitleTrack, at time: Double) -> [SubtitleCue] {
        guard let index = tracks.firstIndex(of: track) else { return [] }
        return SubtitleOverlap.active(at: time, in: layers[index])
    }

    /// 某条轨在这一刻单独显示的字（叠在一起时量它那几行有多高用）。
    func text(of track: SubtitleTrack, at time: Double) -> String? {
        guard let index = tracks.firstIndex(of: track) else { return nil }
        return SubtitleTimeSlicing.text(at: time, layers: [layers[index]])
    }

    /// 烧录用：按时间切好的一段段事件 + 布局。
    var renderBlock: SubtitleRenderBlock {
        SubtitleRenderBlock(cues: SubtitleTimeSlicing.slices(layers), layout: layout)
    }
}

extension TimelineState {

    /// 重叠 cue 排序合同的轨道秩：主轨 0，上层视频轨 1+i，音频再往后；
    /// 无 provenance（外挂/手工 cue）传 nil → -1 排最前；来路不明排最后。
    func subtitleLaneRank(of clipID: UUID?) -> Int {
        guard let clipID else { return -1 }
        if mainClips.contains(where: { $0.id == clipID }) { return 0 }
        for (index, lane) in overlayTracks.enumerated()
        where lane.clips.contains(where: { $0.id == clipID }) { return 1 + index }
        for (index, lane) in audioTracks.enumerated()
        where lane.clips.contains(where: { $0.id == clipID }) {
            return 1 + overlayTracks.count + index
        }
        return Int.max
    }

    // MARK: - 按轨 / 按 ID 找句子

    /// 某条轨上的全部句子（数组顺序 = 时间顺序）。
    func subtitleCues(of track: SubtitleTrack) -> [SubtitleCue] {
        switch track {
        case .original: return subtitle?.cues ?? []
        case .translation: return subtitleCompanion?.translation?.cues ?? []
        }
    }

    /// 两条轨上的全部句子（两条轨上的 ID 互不相同）。
    var allSubtitleCues: [SubtitleCue] {
        subtitleCues(of: .original) + subtitleCues(of: .translation)
    }

    /// 这句在哪条轨上。
    func subtitleTrack(of id: UUID) -> SubtitleTrack? {
        SubtitleTrackEditing.track(of: id, original: subtitle, companion: subtitleCompanion)
    }

    /// 按 ID 找句子（哪条轨都找）。
    func subtitleCue(_ id: UUID) -> SubtitleCue? {
        allSubtitleCues.first { $0.id == id }
    }

    /// 这一句单独藏起来了吗（V，2026-09-26）。藏起来的仍可点可拖可改，只是不进预览、烧录和导出的字幕文件。
    func isSubtitleCueHidden(_ id: UUID) -> Bool {
        subtitleCompanion?.hiddenCueIDs.contains(id) == true
    }

    /// 这条轨的眼睛关着吗。
    func isSubtitleTrackHidden(_ track: SubtitleTrack) -> Bool {
        track == .original ? subtitleHidden : translationHidden
    }

    /// 这条轨存在、而且眼睛开着 —— 看得见就能编辑（**隐藏 = 不可编辑**）。
    func canEditSubtitleTrack(_ track: SubtitleTrack) -> Bool {
        switch track {
        case .original: return subtitle != nil && !subtitleHidden
        case .translation: return hasVisibleTranslation
        }
    }

    /// 有译文轨可显示吗（译文存在**且**它的眼睛开着）。
    var hasVisibleTranslation: Bool {
        !translationHidden && subtitleCompanion?.translation != nil
    }

    /// 两只眼睛推导出的「此刻会显示 / 烧录哪几条轨」。只用来**说**（导出面板的文案），
    /// 画面怎么排看 `subtitleScreenBlocks`。
    var visibleSubtitleChoice: SubtitleTrackChoice? {
        let original = !subtitleHidden && subtitle != nil
        switch (original, hasVisibleTranslation) {
        case (true, true): return .bilingual
        case (true, false): return .original
        case (false, true): return .translation
        case (false, false): return nil
        }
    }

    // MARK: - 画面上排成几块（预览与烧录共用）

    /// 看得见的字幕排成几块。**看得见的就是会被烧进成片的**：预览每一刻画这几块、烧录把这几块
    /// 写成 ASS，两边不许各算一份。眼睛全关（或没有字幕）就是空的。
    func subtitleScreenBlocks() -> [SubtitleScreenBlock] {
        let showsOriginal = !subtitleHidden && subtitle != nil
        let showsTranslation = hasVisibleTranslation
        let original = showsOriginal ? renderedSubtitleCues(of: .original) : []
        let translation = showsTranslation ? renderedSubtitleCues(of: .translation) : []
        if showsOriginal, showsTranslation, translationLayout == nil {
            return [SubtitleScreenBlock(tracks: [.original, .translation], layers: [original, translation], layout: subtitleLayout)]
        }
        var blocks: [SubtitleScreenBlock] = []
        if showsOriginal {
            blocks.append(SubtitleScreenBlock(tracks: [.original], layers: [original], layout: subtitleLayout))
        }
        if showsTranslation {
            // 没有自己的布局 = 叠在原文那一块的位置上（原文藏着时它就占那个位置）。
            blocks.append(SubtitleScreenBlock(
                tracks: [.translation], layers: [translation], layout: translationLayout ?? subtitleLayout
            ))
        }
        return blocks
    }

    /// 某条轨上的句子按重叠合同排好（第 9 节：起点、轨道秩、clipID、cue.id）。译文没有 cueMeta，
    /// 退化成按起点排。
    func orderedSubtitleCues(of track: SubtitleTrack) -> [SubtitleCue] {
        let meta = track == .original ? (subtitleCompanion?.cueMeta ?? [:]) : [:]
        return SubtitleOverlap.ordered(subtitleCues(of: track), meta: meta) { subtitleLaneRank(of: $0) }
    }

    /// 进预览、烧录、导出字幕文件的句子：按重叠合同排好、单句藏起来的（V）不算。
    func renderedSubtitleCues(of track: SubtitleTrack) -> [SubtitleCue] {
        let hidden = subtitleCompanion?.hiddenCueIDs ?? []
        return orderedSubtitleCues(of: track).filter { !hidden.contains($0.id) }
    }

    /// 导出成独立字幕文件的那一份（数据面，**不受眼睛影响** —— 导出 .srt/.vtt 是对数据的显式操作；
    /// 但单句藏起来的不写进去，用户拍板「导出的字幕文件也没有」）。这条轨不存在就是 nil。
    func subtitleDocument(for track: SubtitleTrack) -> SubtitleDocumentModel? {
        let base = track == .original ? subtitle : subtitleCompanion?.translation
        guard var document = base else { return nil }
        document.cues = renderedSubtitleCues(of: track)
        document.reindex()
        return document
    }

    // MARK: - 改字幕的公共骨架

    /// 两条轨和旁表一起改，改完空 companion 收回 nil。
    /// 工程层的每个字幕入口、拖动落地、裁切都走这里，别各自写一遍「取出来、改、放回去」。
    ///
    /// 还没有原文轨时：`creatingOriginal`（手写第一行字幕）就先垫一条空的；否则什么也不做 ——
    /// 凭空垫一条空轨，时间线上就多出一行空字幕。
    mutating func editSubtitleTracks(
        creatingOriginal: Bool = false,
        _ body: (inout SubtitleDocumentModel, inout SubtitleCompanion) -> Void
    ) {
        guard subtitle != nil || creatingOriginal else { return }
        var original = subtitle ?? SubtitleDocumentModel(format: .srt)
        var companion = subtitleCompanion ?? SubtitleCompanion(origin: .imported)
        body(&original, &companion)
        subtitle = original
        subtitleCompanion = companion.hasPersistentData ? companion : nil
    }
}
