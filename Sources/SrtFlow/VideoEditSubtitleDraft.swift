import SwiftUI
import SrtFlowCore

/// 正在被输入、还没落进模型的那一格字幕文本。
///
/// **草稿放在工程上，不放视图的 `@State`**（2026-08-12 复审 P1）。保存、新建、打开、
/// 退出这几条路全是「先读 `state` 写盘，再销毁视图」，而视图里的草稿要等失焦或
/// `onDisappear` 才提交 —— 于是「输入 → ⌘S」存下去的是旧文本，「输入 → 退出」直接
/// 丢字。放在工程上之后，`commitSubtitleDraft()` 能在读模型**之前**同步落定，
/// 不依赖任何回调时机。
///
/// 焦点只有一个，所以同时只可能有一格在输入 —— 只存一份。
/// 一格 = 一句（2026-09-26 起原文、译文各是各的句子，ID 互不相同，按 ID 就知道是哪条轨的）。
struct SubtitleTextDraft: Equatable {
    var cueID: UUID
    var text: String
    /// 进入这一格时模型里的值。**一次编辑会话内绝不重算**（复审 P1）：重算的话，
    /// 编辑期间别处（右栏、重译写回）把同一条改成 C，基线也跟着变成 C，
    /// 旧草稿 B 反而通过了 CAS，把更新的 C 盖掉。
    var baseline: String?
}

extension VideoEditProject {

    /// 光标进到某一格：开一份草稿。切格子时先把上一格落定 ——
    /// 焦点转移的两个 `onChange`（旧格子提交、新格子开始）到达顺序是不保证的，
    /// 所以两边都要能兜住对方。
    func beginSubtitleDraft(cueID: UUID) {
        if let draft = subtitleDraft, draft.cueID != cueID {
            commitSubtitleDraft()
        }
        guard subtitleDraft == nil else { return }
        let baseline = subtitleModelText(cueID: cueID)
        subtitleDraft = SubtitleTextDraft(cueID: cueID, text: baseline ?? "", baseline: baseline)
    }

    /// 输入中的每一次改动。**只动草稿、不动模型** —— 每敲一个字记一步撤销是灾难，
    /// 而且模型一变字幕表的行身份就跟着变，光标当场就没了。
    func updateSubtitleDraft(cueID: UUID, text: String) {
        if subtitleDraft?.cueID != cueID { beginSubtitleDraft(cueID: cueID) }
        subtitleDraft?.text = text
    }

    /// 把挂着的草稿落进模型（走合同入口，一格 = 一步撤销）。
    ///
    /// **保存、切工程、退出前必须先调这个。** 返回是否真写了东西。
    @discardableResult
    func commitSubtitleDraft() -> Bool {
        guard let draft = subtitleDraft else { return false }
        subtitleDraft = nil
        guard draft.text != (draft.baseline ?? "") else { return false }
        // CAS：模型仍等于进入编辑时的基线才写。别处（重译写回、另一个入口）
        // 已经改过这一格的话，草稿作废 —— 新结果优先。
        let current = subtitleModelText(cueID: draft.cueID)
        guard current == draft.baseline else { return false }
        setSubtitleCueText(id: draft.cueID, text: draft.text)
        return true
    }

    /// 丢弃草稿（这条 cue 被删掉、字幕轨被换掉时）。
    func discardSubtitleDraft() { subtitleDraft = nil }

    /// 输入框此刻该显示什么：这一格正在输入就显示草稿，否则显示模型里的值。
    func subtitleTextBinding(cueID: UUID) -> Binding<String> {
        Binding(
            get: { [weak self] in
                guard let self else { return "" }
                if let draft = self.subtitleDraft, draft.cueID == cueID { return draft.text }
                return self.subtitleModelText(cueID: cueID) ?? ""
            },
            set: { [weak self] newValue in self?.updateSubtitleDraft(cueID: cueID, text: newValue) }
        )
    }

    /// 模型里那一句的文本（哪条轨都找）。这句已经不在了就是 nil。
    func subtitleModelText(cueID: UUID) -> String? {
        state.subtitleCue(cueID)?.text
    }
}
