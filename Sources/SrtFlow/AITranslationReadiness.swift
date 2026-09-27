import AppKit
import Foundation
import Translation

// MARK: - 翻译之前的两件事：原文到底是什么语言、这一对语言装没装
//
// 管什么：
// 1. **原文按字判断语言**（`AITextLanguage`，系统自带的 NaturalLanguage），不信工程里记着的旧语言 —— AI 可能刚把原文
//    整轨改写成另一种语言（2026-09-27 实测：原文改成了中文，工程里还记着英文，系统就按「英文→韩文」
//    去翻中文字幕，docs/bugfixes/2026-09-27-ai-translation-stale-source-language.md）。
// 2. **这一对语言要不要先下载**。要的话 macOS 会弹「下载翻译语言」的框，而且**只能由用户点**：
//    苹果不给静默下载的接口。所以要把 SrtFlow 摆到最前面、告诉 AI 让用户去点、提示条上也写清楚 ——
//    不然任务停在 0%，AI 以为在下载，用户以为软件坏了（用户原话：「应该引导下用户，去点击下载」）。
// 不管什么：翻译本身（SubtitleTranslationService，面板上那一个）。

@MainActor
enum AITranslationReadiness {
    /// 这一对语言还要不要先下载（`.supported` = 支持但没装；装好了是 `.installed`）。
    @available(macOS 15.0, *)
    static func needsDownload(from source: String, to target: String) async -> Bool {
        await LanguageAvailability().status(
            from: Locale.Language(identifier: source), to: Locale.Language(identifier: target)
        ) == .supported
    }

    /// 系统已经在出译文了：下载早就完了（或者本来就不用下），不用再提醒用户。
    /// 直接翻译和「生成完接着翻」都走同一个协调器，两条路共用这一个判断。
    @available(macOS 15.0, *)
    static var isProducingTranslations: Bool {
        if case .running(let completed, _) = TranslationJobCoordinator.shared.phase { return completed > 0 }
        return false
    }

    /// 系统的下载框挂在主窗口上：窗口必须真的到前面来、App 必须激活，用户才看得见、点得着。
    /// 这是 AI 接口里**唯一**故意抢前台的地方（平时只摆窗口、不抢键盘，见 AIEditorPresenter）。
    static func bringSrtFlowForward() {
        NSApp.activate()
        AIEditorPresenter.mainWindow()?.makeKeyAndOrderFront(nil)
    }

    static func englishName(_ tag: String) -> String {
        Locale(identifier: "en").localizedString(forIdentifier: tag) ?? tag
    }
}

/// 等用户下载翻译语言的那一阵子：**自己每两秒问一次系统「装好了没」**，把真实状态告诉提示条和 AI。
///
/// 为什么不能只靠系统那个下载框：它的进度条在 SrtFlow 不在最前面时常常不刷新 —— 2026-09-27 用户实测，
/// 系统设置里韩语已经下到七成，SrtFlow 里那个框还停在开头，「好像卡住了一样」。
@MainActor
final class AIDownloadWatch {
    let source: String
    let target: String
    private(set) var downloaded = false
    private var task: Task<Void, Never>?

    init(source: String, target: String) {
        self.source = source
        self.target = target
    }

    /// 给 AI 的那句：它要转述给用户，而不是闷着头一直等。
    var note: String {
        if downloaded {
            return "The translation languages are downloaded. If the macOS download dialog is still open in SrtFlow, "
                + "tell the user to click Done; translating then starts."
        }
        return """
            This Mac is downloading the \(AITranslationReadiness.englishName(source)) and \(AITranslationReadiness.englishName(target)) \
            translation languages (one time only). SrtFlow is in front with a macOS dialog: tell the user to click Download \
            next to each language if they have not yet, and that the dialog's progress bar can lag, while System Settings > \
            General > Language & Region > Translation Languages shows the real progress. Keep waiting with get_job; \
            the job continues by itself after the download.
            """
    }

    /// 提示条上给用户看的那句。
    var hint: String {
        downloaded
            ? L10n("The translation languages are downloaded. If the download window is still open, click Done and translating starts.")
            : L10n("Downloading the translation languages. In the window that opened, click Download next to each language if you haven't yet. Its progress bar can lag: System Settings › General › Language & Region › Translation Languages shows the real progress.")
    }

    /// 摆出 SrtFlow、挂上提示、开始盯。`isOver`：翻译已经开始出结果、或者任务结束了 —— 不用再盯。
    func start(isOver: @escaping @MainActor () -> Bool) {
        AITranslationReadiness.bringSrtFlowForward()
        AISession.shared.setHint(hint)
        task = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                if isOver() {
                    AISession.shared.setHint(nil)
                    return
                }
                if !self.downloaded, await !AITranslationReadiness.needsDownload(from: self.source, to: self.target) {
                    self.downloaded = true
                    AISession.shared.setHint(self.hint)
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func stop() {
        task?.cancel()
        AISession.shared.setHint(nil)
    }
}
