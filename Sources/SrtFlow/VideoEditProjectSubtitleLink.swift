import Foundation
import SrtFlowCore

// 关联字幕编辑合同的工程层入口（docs/plans/2026-08-06-native-subtitle-generation.md
// 第 8 节）。规则本体是 SrtFlowCore 的 LinkedSubtitleEditing 纯函数（那边有单测）；
// 这里只负责把每条合同操作包进一次 perform —— 撤销、脏标记、自动保存自动正确。
// UI（双轨编辑器 / 生成面板）从 Phase 2 起调用这些入口。

extension VideoEditProject {

    /// 合同 0：生成替换 —— 原文轨整体换成生成结果，旧译文/meta 同一事务清掉。
    /// 已有原文时**调用方必须先向用户确认**（本方法只做事务，不做交互）。
    func replaceSubtitleForGeneration(
        _ document: SubtitleDocumentModel,
        sourceLanguage: String?,
        generation: GenerationSnapshot?,
        cueMeta: [UUID: CueMeta] = [:]
    ) {
        perform { state in
            state.subtitle = document
            state.subtitleURL = nil
            state.subtitleCompanion = SubtitleCompanion(
                sourceLanguage: sourceLanguage,
                origin: .generated,
                generation: generation,
                cueMeta: cueMeta
            )
        }
    }

    /// 给现有原文轨（外挂/导入）挂上译文。cue 必须与原文同 ID —— 由翻译服务保证。
    func setSubtitleTranslation(_ translation: SubtitleDocumentModel?, targetLanguage: String?) {
        perform { state in
            guard state.subtitle != nil else { return }
            var companion = state.subtitleCompanion ?? SubtitleCompanion(origin: .imported)
            companion.translation = translation
            companion.targetLanguage = targetLanguage
            state.subtitleCompanion = companion.hasPersistentData ? companion : nil
        }
    }

    /// 翻译结果回写：按 cueID 更新/补建译文 cue（时间抄原文），清这些条的
    /// stale。一次 perform = 一步撤销。译文 cue 顺序跟随原文轨。
    func applyTranslations(
        _ texts: [UUID: String], sourceLanguage: String?, targetLanguage: String?
    ) {
        guard !texts.isEmpty else { return }
        perform(rebuildsPreview: false) { state in
            guard let original = state.subtitle else { return }
            var companion = state.subtitleCompanion ?? SubtitleCompanion(origin: .imported)
            var doc = companion.translation ?? SubtitleDocumentModel()
            let existing: [UUID: String] = Dictionary(
                uniqueKeysWithValues: doc.cues.map { ($0.id, $0.text) }
            )
            // 重建为「按原文顺序」的镜像轨：有新译文用新的，没有的保留旧译文。
            doc.cues = original.cues.compactMap { cue in
                let text = texts[cue.id] ?? existing[cue.id]
                guard let text else { return nil }
                var mirror = cue
                mirror.text = text
                return mirror
            }
            doc.reindex()
            companion.translation = doc.cues.isEmpty ? nil : doc
            companion.sourceLanguage = sourceLanguage ?? companion.sourceLanguage
            companion.targetLanguage = targetLanguage ?? companion.targetLanguage
            for id in texts.keys {
                var meta = companion.cueMeta[id] ?? CueMeta()
                meta.translationStale = false
                companion.cueMeta[id] = meta
            }
            state.subtitleCompanion = companion.hasPersistentData ? companion : nil
        }
    }

    /// 合同 1：改时间（两轨同步）。
    func linkedSetCueTime(id: UUID, start: TimeInterval, end: TimeInterval) {
        performLinked { original, companion in
            LinkedSubtitleEditing.setTime(
                id: id, start: start, end: end, original: &original, companion: &companion
            )
        }
    }

    /// 合同 2：改原文文本（译文标过期、置信度作废）。
    func linkedSetOriginalText(id: UUID, text: String) {
        performLinked { original, companion in
            LinkedSubtitleEditing.setOriginalText(
                id: id, text: text, original: &original, companion: &companion
            )
        }
    }

    /// 合同 3：改译文文本（清 stale）。
    func linkedSetTranslationText(id: UUID, text: String) {
        performLinked { original, companion in
            LinkedSubtitleEditing.setTranslationText(
                id: id, text: text, original: &original, companion: &companion
            )
        }
    }

    /// 合同 4：删除（两轨 + meta 同删）。
    func linkedRemoveCues(ids: Set<UUID>) {
        performLinked { original, companion in
            LinkedSubtitleEditing.removeCues(ids: ids, original: &original, companion: &companion)
        }
    }

    /// 合同 5：拆分（首条留 ID、次条新 UUID、两轨一致、译文后半置空并标 stale）。
    func linkedSplitCue(id: UUID, at time: TimeInterval) {
        performLinked { original, companion in
            LinkedSubtitleEditing.splitCue(
                id: id, at: time, original: &original, companion: &companion
            )
        }
    }

    /// 合同 6：合并（沿用首条 ID、删其余 meta、标 stale）。
    func linkedMergeCues(ids: Set<UUID>) {
        performLinked { original, companion in
            LinkedSubtitleEditing.mergeCues(ids: ids, original: &original, companion: &companion)
        }
    }

    /// 合同 7：新增一条。返回新 cue 的 ID —— 调用方要立刻把它选中并聚焦，
    /// 不然用户看见的是「按了 + 什么也没发生」（新条是空文本）。
    ///
    /// **还没有字幕轨时就地建一条空轨**：手写字幕是合法起点，不该逼用户先去
    /// 外挂一个 .srt 或者跑一次识别。
    @discardableResult
    func linkedInsertCue(at time: TimeInterval, duration: TimeInterval = 2) -> UUID? {
        var created: UUID?
        perform(rebuildsPreview: false) { state in
            var original = state.subtitle ?? SubtitleDocumentModel(format: .srt)
            var companion = state.subtitleCompanion ?? SubtitleCompanion(origin: .imported)
            created = LinkedSubtitleEditing.insertCue(
                at: time, duration: duration, original: &original, companion: &companion
            )
            guard created != nil else { return }
            state.subtitle = original
            state.subtitleCompanion = companion.hasPersistentData ? companion : nil
        }
        return created
    }

    /// 公共骨架：一次 perform = 一步撤销；空 companion 收敛回 nil。
    /// 字幕不参与 AV 合成，改动不用重建预览播放器。
    private func performLinked(
        _ mutate: (inout SubtitleDocumentModel, inout SubtitleCompanion) -> Void
    ) {
        perform(rebuildsPreview: false) { state in
            guard var original = state.subtitle else { return }
            var companion = state.subtitleCompanion ?? SubtitleCompanion()
            mutate(&original, &companion)
            state.subtitle = original
            state.subtitleCompanion = companion.hasPersistentData ? companion : nil
        }
    }
}

// 轨道选择的消费端助手（subtitleDocument / visibleSubtitleDocument）在
// VideoEditSubtitleDocuments.swift —— 独立成文件是为了让 checks/ProjectFile
// 能把 TimelineState 侧的合同单独编进自检。
