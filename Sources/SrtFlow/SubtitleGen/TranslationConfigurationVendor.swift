import Foundation
import Translation

// 翻译任务的 configuration 发放器（docs/bugfixes/2026-08-09-translate-stuck-at-zero.md）。
//
// 为什么需要它：`TranslationSession.Configuration` 是**带 `version` 的值类型**，
// `==` 把 version 一起比。每次任务各自 `Configuration(source:target:)` 新建一个，
// 两次**同样语言**的任务拿到的配置就完全相等（version 都是 0）——
// SwiftUI 的 `.translationTask` 按「配置变了才重跑 action」的语义判定没变化，
// action 不再执行，`TranslationJobCoordinator.run(session:jobID:)` 永远收不到
// session，continuation 永久悬挂：面板停在 0/N，只能按 Stop。
//
// Apple 给的换代通道就是 `invalidate()`（它把 version +1、保留语言）。
// 这里把「每次发的配置都与之前不相等」做成硬不变量：**永远 invalidate**，
// 语言变了就改字段而不是重建，于是 version 在 App 生命周期内单调递增。
//
// 纯值逻辑，checks/TranslationPreflight 编进去做守卫。

@available(macOS 15.0, *)
struct TranslationConfigurationVendor {
    private var current: TranslationSession.Configuration?

    /// 发一份**保证与之前任何一份都不相等**的配置。
    ///
    /// 不要改成「语言相同就复用、语言不同才新建」：新建出来的 version 从 0 起，
    /// 一旦语言在 A→B→A 之间来回切，就可能又和更早发过的那份撞上。
    /// 只保留一条流水线、每次都换代，是唯一不用推理时序就成立的写法。
    mutating func next(
        source: Locale.Language?, target: Locale.Language?
    ) -> TranslationSession.Configuration {
        var config = current ?? TranslationSession.Configuration(source: source, target: target)
        config.source = source
        config.target = target
        config.invalidate()
        current = config
        return config
    }
}
