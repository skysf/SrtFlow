import Foundation
import SrtFlowCore

// 轨道选择的消费端助手（预览与烧录共用，计划第 9 节合同）。
// 从 VideoEditProjectSubtitleLink.swift 拆出：纯 TimelineState 逻辑，
// checks/ProjectFile 把本文件编进自检（可见性合同 2026-08-09）。

extension TimelineState {

    /// 重叠 cue 排序合同的轨道秩：主轨 0，画中画 1+i，音频再往后；
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

    /// 有译文轨可显示吗（译文存在**且**它的眼睛开着）。
    var hasVisibleTranslation: Bool {
        !translationHidden && subtitleCompanion?.translation != nil
    }

    /// 两只眼睛推导出的轨道选择。**一个语言一条轨**：
    /// 都开=双语、只开一条=那一条、都关（或没有字幕）=nil。
    ///
    /// 这取代了以前的「Preview track」模式选择器：显示什么不再是一个额外的
    /// 模式，而是「哪几条轨看得见」的自然结果，与主轨/画中画/音频的眼睛同一
    /// 心智（2026-08-09 用户拍板）。
    var visibleSubtitleChoice: SubtitleTrackChoice? {
        let original = !subtitleHidden && subtitle != nil
        switch (original, hasVisibleTranslation) {
        case (true, true): return .bilingual
        case (true, false): return .original
        case (false, true): return .translation
        case (false, false): return nil
        }
    }

    /// 预览与烧录共用的可见性合同：**看得见的就是会被烧进成片的**。
    /// 两只眼睛都关就是 nil（与其他轨道的隐藏语义一致）。
    /// 独立字幕文件导出**不走这里** —— 导出 .srt/.vtt 是对数据的显式操作，
    /// 不是可见性，故意不受眼睛影响。
    func visibleSubtitleDocument() -> SubtitleDocumentModel? {
        guard let choice = visibleSubtitleChoice else { return nil }
        return subtitleDocument(for: choice)
    }

    /// 按轨道选择合成要显示/烧录的文档，cue 顺序已按第 9 节合同排定。
    /// 译文轨不存在时选译文返回 nil（调用方决定按钮置灰还是回退）。
    func subtitleDocument(for choice: SubtitleTrackChoice) -> SubtitleDocumentModel? {
        guard let original = subtitle else { return nil }
        guard var document = SubtitleExportPlanner.document(
            for: choice,
            original: original,
            translation: subtitleCompanion?.translation
        ) else { return nil }
        let meta = subtitleCompanion?.cueMeta ?? [:]
        document.cues = SubtitleOverlap.ordered(document.cues, meta: meta) {
            subtitleLaneRank(of: $0)
        }
        document.reindex()
        return document
    }
}

/// 时间线上的字幕行属于哪条轨。**一个语言一条轨**：原文一行、译文一行，
/// 各自一只眼睛（合同见 docs/architecture/subtitle-track-visibility-and-layout.md）。
enum SubtitleRowKind {
    case original
    case translation
}
