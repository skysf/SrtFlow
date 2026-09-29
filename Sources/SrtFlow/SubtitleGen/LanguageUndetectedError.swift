import Foundation

// MARK: - 自动检测没认出说的是哪种话
//
// 管什么：`TranscriptHarvester` 自动检测语言失败时抛的错（候选语言都没听出够多的词：片段里只有音乐、环境声，或者说得太少）。
// 单独一个类型、不挂在只在 macOS 26 上有的 TranscriptHarvester 里面，调用方才认得出它：面板照旧说「去面板里选」，
// AI 那边换成「带上 language 再调」（`AIHarvestFailure`；2026-09-29 验收实剪，AI 拿到「去面板里选」无从下手，
// docs/bugfixes/2026-09-29-ai-told-to-pick-language-in-panel.md）。
// 不管什么：怎么检测（TranscriptHarvester / SubtitleLanguageDetection）。

struct LanguageUndetectedError: LocalizedError {
    var errorDescription: String? {
        L10n("Couldn't confidently detect the spoken language. Pick it in the panel and generate again.")
    }
}
