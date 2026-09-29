import Foundation

// MARK: - 转写 / 生成字幕失败时回给 AI 的话
//
// 管什么：transcribe、generate_subtitles 的任务失败时，get_job 里写什么。大多数错误原样交给 AI；自动检测没认出语言时，
// 界面的那句「去面板里选」AI 做不到（它没有面板），换成它能照做的：有人说话就带上 language 再调，没人说话就不用转了
// （2026-09-29，docs/bugfixes/2026-09-29-ai-told-to-pick-language-in-panel.md）。
// 不管什么：错误从哪来（LanguageUndetectedError、TranscriptionTask）。

enum AIHarvestFailure {
    /// - Parameter retry: 叫 AI 再调的那个工具（transcribe / generate_subtitles）。
    static func message(for error: Error?, fallback: String, retry tool: String) -> String {
        guard error is LanguageUndetectedError else { return fallback }
        return "Couldn't tell which language is spoken: the clips may hold only music or ambient sound, or too few words. "
            + "If someone speaks, call \(tool) again with language (for example en or zh-Hans); if nobody speaks, there is "
            + "nothing to transcribe."
    }
}
