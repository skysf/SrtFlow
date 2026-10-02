import Foundation

// MARK: - AI 起的 fal 任务共用的两样：花钱的把关、钥匙串授权框的提醒
//
// 管什么：（1）**先问后花**（方案第 18 条）：额度内直接记账；这一次会让今天超过每日上限、或者模型没登记单价，先在**顶上的提示条**上问用户
//（`AISession.ask`：两个按钮，不弹模态框）。提示条只挂在剪辑页里，问之前先把剪辑页摆出来、把 SrtFlow 摆到前面（后台模式也一样：
// 要用户点头的事不能悄悄等）；问的时候任务的 `waiting_for_user` 写清在等什么（AI 转述给用户）。决定和记账在同一步里做完（中间没有 await），
// 同时起的几个任务不会各自以为还在额度内。（2）钥匙串的授权框只能由用户点：给 AI 的那句话、提示条上的那一句。
// generate_media（FalGenerationRun）和 upscale_clip（UpscaleJob）都走这里 —— 规则只有一处（checks/fal-wiring.sh 第 4、5 条钉着）。
// 不管什么：退款（各任务自己：没做出来才退）、面板起的 upscale（面板本身就是确认，不经这里）。

@MainActor
enum FalJobGate {
    /// 记上账的那一笔（退款时按这一天退）。
    struct Reservation: Equatable {
        let amount: Double
        let day: Date
    }

    enum Outcome {
        case reserved(Reservation)
        /// 用户按了「先不要」或停止：没花钱。
        case declined
    }

    /// `summary`：「MiniMax H3 Max · 5 s · 768P」这种不带语言的几个记号；`owner`：问题挂在谁名下（取消时按它收回）；
    /// `waiting`：问的时候任务的 `waiting_for_user` 怎么写（问完清掉）。
    static func reserve(
        estimate: Double?, summary: String, owner: String, project: VideoEditProject, waiting: @MainActor (String?) -> Void
    ) async -> Outcome {
        let store = FalSettingsStore.shared
        switch store.decide(estimate: estimate) {
        case .allow:
            return .reserved(record(store, estimate))
        case .ask(let reason):
            let texts = questionTexts(reason, summary)
            waiting(
                "SrtFlow is asking the user to approve this cost on the bar at the top of its window (it is in front now): "
                    + texts.english + " Tell the user to answer there, then keep waiting with get_job."
            )
            try? await AIEditorPresenter.prepareEditor(project: project, bringForward: true)
            AITranslationReadiness.bringSrtFlowForward()
            let allowed = await AISession.shared.ask(texts.localized, allow: L10n("Allow"), decline: L10n("Not Now"), owner: owner)
            waiting(nil)
            guard allowed, !Task.isCancelled else { return .declined }
            return .reserved(record(store, estimate))
        }
    }

    private static func record(_ store: FalSettingsStore, _ estimate: Double?) -> Reservation {
        let amount = estimate ?? 0
        store.recordSpend(amount)
        return Reservation(amount: amount, day: Date())
    }

    /// 提示条上问的话（跟着界面语言）和给 AI 的英文原话。
    static func questionTexts(_ reason: FalSpendPolicy.Reason, _ summary: String) -> (localized: String, english: String) {
        switch reason {
        case .unknownPrice:
            return (
                String(format: L10n("fal.ai · %@ — SrtFlow does not know this model's price, so it asks each time. Allow?"), summary),
                "fal.ai · \(summary) — SrtFlow does not know this model's price, so it asks each time."
            )
        case .overLimit(let spent, let estimate, let limit):
            let total = FalMoney.text(spent + estimate)
            return (
                String(format: L10n("fal.ai · %@ — estimated cost %@. Today's spending would reach %@, over your %@ daily limit. Allow?"),
                       summary, FalMoney.text(estimate), total, FalMoney.text(limit)),
                "fal.ai · \(summary) — estimated cost \(FalMoney.text(estimate)); today's spending would reach \(total), over the user's "
                    + "\(FalMoney.text(limit)) daily limit."
            )
        }
    }

    // MARK: 钥匙串的授权框

    /// AI 看 get_job 只见 running：得让它知道是 macOS 的授权框在等用户（不然它会对着一个「没动静」的任务干等）。
    static let keyPromptWaiting = "macOS is asking the user, in a system dialog, whether SrtFlow may use the fal.ai key. Tell the user to click "
        + "Always Allow (a Mac login password may be needed; a new version of SrtFlow is asked once), then keep waiting with get_job."

    /// 提示条上说一句、把剪辑页摆出来（提示条在剪辑页里）、把 SrtFlow 摆到前面（授权框跟着 App）。
    static func showKeyPromptHint() {
        AISession.shared.setHint(L10n("macOS is about to ask whether SrtFlow may use your fal.ai key. Click Always Allow."))
        if MainWindowState.shared.section != .videoEdit { MainWindowState.shared.section = .videoEdit }
        AITranslationReadiness.bringSrtFlowForward()
    }

    static func clearKeyPromptHint() {
        AISession.shared.setHint(nil)
    }
}
