import Foundation
import SrtFlowCore

// 字幕编辑合同的工程层入口。规则本体是 SrtFlowCore 的纯函数（`SubtitleTrackEditing`、
// `SubtitleRetranslation`，那边有自检）；这里只负责把每条合同操作包进一次 perform ——
// 撤销、脏标记、自动保存自动正确。字幕不参与 AV 合成，改动不用重建预览播放器。
//
// 2026-09-26 起原文、译文是两条独立的轨（docs/plans/2026-09-26-hide-guides-independent-subtitles.md）：
// 每个入口只动这句所在的那条轨；以前叫 `linked…`（两轨一起动），现在按轨各改各的。

extension VideoEditProject {

    /// 生成替换 —— 原文轨整体换成生成结果，旧译文/meta 同一事务清掉。
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
            state.translationLayout = nil
            state.subtitleCompanion = SubtitleCompanion(
                sourceLanguage: sourceLanguage,
                origin: .generated,
                generation: generation,
                cueMeta: cueMeta
            )
        }
    }

    /// 翻译结果回写（`SubtitleRetranslation.apply`：全部重建 / 只补缺的和换过期的）。一次 perform = 一步撤销。
    /// `results` 的键是原文 cue 的 ID；`snapshot` 是送去翻的时候那几句原文的字。
    func applyTranslations(
        _ results: [UUID: String], snapshot: [UUID: String], scope: SubtitleRetranslation.Scope,
        sourceLanguage: String?, targetLanguage: String?
    ) {
        // 一句都没翻回来就什么也不动 —— 「全部翻译」拿空结果去重建，会把整条译文轨清空。
        guard !results.isEmpty else { return }
        perform(rebuildsPreview: false) { state in
            guard let original = state.subtitle else { return }
            var companion = state.subtitleCompanion ?? SubtitleCompanion(origin: .imported)
            SubtitleRetranslation.apply(results, snapshot: snapshot, scope: scope, original: original, companion: &companion)
            companion.sourceLanguage = sourceLanguage ?? companion.sourceLanguage
            companion.targetLanguage = targetLanguage ?? companion.targetLanguage
            state.subtitleCompanion = companion.hasPersistentData ? companion : nil
        }
    }

    /// 改时间（只动这句所在的那条轨）。
    func setSubtitleCueTime(id: UUID, start: TimeInterval, end: TimeInterval) {
        performSubtitleEdit { original, companion in
            SubtitleTrackEditing.setTime(id: id, start: start, end: end, original: &original, companion: &companion)
        }
    }

    /// 改字（原文：置信度作废，它的译文现算成过期；译文：跟上现在的原文、记「字手改过」）。
    func setSubtitleCueText(id: UUID, text: String) {
        performSubtitleEdit { original, companion in
            SubtitleTrackEditing.setText(id: id, text: text, original: &original, companion: &companion)
        }
    }

    /// 删除（这批句子在哪条轨上就从哪条删；原文删了，译文不跟着删）。
    func removeSubtitleCues(ids: Set<UUID>) {
        performSubtitleEdit { original, companion in
            SubtitleTrackEditing.removeCues(ids: ids, original: &original, companion: &companion)
        }
    }

    /// 拆成两句（只拆这句所在的那条轨）。
    func splitSubtitleCue(id: UUID, at time: TimeInterval) {
        performSubtitleEdit { original, companion in
            SubtitleTrackEditing.splitCue(id: id, at: time, original: &original, companion: &companion)
        }
    }

    /// 合并（只合同一条轨上的；跨两条轨什么也不做 —— 按钮那边已经置灰）。
    func mergeSubtitleCues(ids: Set<UUID>) {
        performSubtitleEdit { original, companion in
            SubtitleTrackEditing.mergeCues(ids: ids, original: &original, companion: &companion)
        }
    }

    /// 新加一句到指定的轨。返回新 cue 的 ID —— 调用方要立刻把它选中并聚焦，
    /// 不然用户看见的是「按了 + 什么也没发生」（新句是空文本）。
    ///
    /// **还没有字幕轨时就地建一条空的原文轨**：手写字幕是合法起点，不该逼用户先去
    /// 外挂一个 .srt 或者跑一次识别。
    @discardableResult
    func insertSubtitleCue(at time: TimeInterval, duration: TimeInterval = 2, into track: SubtitleTrack) -> UUID? {
        var created: UUID?
        perform(rebuildsPreview: false) { state in
            state.editSubtitleTracks(creatingOriginal: true) { original, companion in
                created = SubtitleTrackEditing.insertCue(
                    at: time, duration: duration, into: track, original: &original, companion: &companion
                )
            }
        }
        return created
    }

    // MARK: - 整条轨：挂上 / 拿掉、眼睛、画面上的位置、点选（从 VideoEditProject.swift 挪来）

    /// 外挂一份 .srt / .vtt 当原文轨。
    func attachSubtitle(_ url: URL) {
        do {
            let document = try SubtitleLoader.load(url)
            perform { state in
                state.subtitle = document
                state.subtitleURL = url
                // 换了原文轨，旧译文/cueMeta/译文的位置同一事务清掉（用户拍板：换原文照旧清译文）。
                state.subtitleCompanion = nil
                state.translationLayout = nil
            }
        } catch {
            notice = error.localizedDescription
        }
    }

    func removeSubtitle() {
        perform { state in
            state.subtitle = nil
            state.subtitleURL = nil
            state.subtitleCompanion = nil
            state.translationLayout = nil
        }
    }

    /// **原文**字幕轨的眼睛。语义与其他轨道一致：预览和烧录都跳过。
    /// 字幕不参与 AV 合成，不用重建预览播放器。
    func toggleSubtitleHidden() {
        perform(rebuildsPreview: false) { $0.subtitleHidden.toggle() }
    }

    /// **译文**字幕轨的眼睛。一个语言一条轨，各自一只眼睛（`TimelineState.subtitleScreenBlocks`）。
    func toggleTranslationHidden() {
        perform(rebuildsPreview: false) { $0.translationHidden.toggle() }
    }

    /// 预览拖框实时写入字幕布局（liveApply 连续编辑，松手 endLiveEdit(rebuildsPreview: false) 合成一步撤销）。
    /// `track` 是被拖的那条轨；两条叠在一起时拖任何一条就此分开（计划 S8）：另一条钉在 `pinning`（它此刻的位置）。
    func liveSetSubtitleLayout(_ layout: SubtitleLayout, for track: SubtitleTrack, pinning other: SubtitleLayout? = nil) {
        liveApply { state in
            if track == .original { state.subtitleLayout = layout } else { state.translationLayout = layout }
            if let other, track == .original { state.translationLayout = other }
            if let other, track == .translation { state.subtitleLayout = other }
        }
    }

    /// 译文叠回原文下面（字幕表表头的开关，计划 S9）。
    func stackTranslationUnderOriginal() {
        perform(rebuildsPreview: false) { $0.translationLayout = nil }
    }

    /// 点选字幕 cue：与剪辑、形状选择都互斥（互斥规则在 `EditSelection`）。
    /// ⌘/⇧ 点是加选或取消，和剪辑、形状一致。
    func selectSubtitleCue(_ id: UUID, additive: Bool = false) {
        if additive {
            var ids = selectedSubtitleCueIDs
            if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
            selectedSubtitleCueIDs = ids
        } else {
            selectedSubtitleCueIDs = [id]
        }
    }

    /// 公共骨架：一次 perform = 一步撤销。没有原文轨时什么也不做。
    private func performSubtitleEdit(_ mutate: (inout SubtitleDocumentModel, inout SubtitleCompanion) -> Void) {
        perform(rebuildsPreview: false) { state in state.editSubtitleTracks(mutate) }
    }
}

// 两条轨的读法与「画面上排成几块」在 VideoEditSubtitleDocuments.swift ——
// 独立成文件是为了让 checks/ProjectFile 能把 TimelineState 侧的合同单独编进自检。
