import Foundation
import SrtFlowCore

// formatVersion 按需写入（docs/plans/2026-08-06-native-subtitle-generation.md 7.4）：
// reader 认到 v4，writer 只在真的存在 v4-only 数据时才写 4，普通工程继续写 3 ——
// 版本闸门只对真正用了新功能的工程关门。

extension TimelineState {
    /// 是否存在「旧版打开会被静默丢掉」的 v4-only 持久数据。
    ///
    /// **登记清单（新增 v4-only 字段必须同步补进来，漏了 = 旧版静默毁数据）：**
    /// 1. `subtitleCompanion` —— 译文轨 / cueMeta / 语言与生成参数。
    ///
    /// 判据必须枚举全部 v4-only 字段，不允许只检查某一个类型名了事；
    /// 每次保存都重算，删光 v4 数据的工程自动降回 v3（有回归用例）。
    var requiresFormatVersion4: Bool {
        subtitleCompanion?.hasPersistentData == true
    }

    /// 是否存在「旧版打开会被静默丢掉」的 v5-only 持久数据。
    ///
    /// **登记清单（新增 v5-only 字段必须同步补进来）：**
    /// 1. `frameRate` —— 工程帧率。**无条件**算 v5 数据。
    ///
    /// 曾经写成「只有非默认（≠24）才算」，那是错的：v4 及更早的版本把帧率
    /// **硬编码成 30**（`VideoEditCompositionBuilder` 的 `frameDuration = 1/30`、
    /// 导出滤镜的 `fps=30`）。默认 24 的工程若不写这个键、还降版成 v3，旧版
    /// 打开会按 30 fps 渲染 —— 同一个文件在新旧版里出不同的成片，正是版本
    /// 闸门要防的语义破坏。只要是新版写出的工程，帧率就必须显式落盘并锁 v5。
    ///
    /// 回退只发生在**读**：v1–v4 的老文件没有这个键，按 24 回退（那些文件
    /// 本来就没有帧率语义，选 24 是产品默认值，不是在猜旧行为）。
    var requiresFormatVersion5: Bool { true }

    /// 读盘后的规范化：companion 的译文轨/cueMeta 必须锚在现有原文 cue 上，
    /// 对不上的是坏数据（外部改动、半截文件），静默清掉而不是带病运行。
    mutating func normalizeSubtitleCompanion() {
        guard var companion = subtitleCompanion else { return }
        let ids = Set((subtitle?.cues ?? []).map(\.id))
        companion.normalize(originalCueIDs: ids)
        subtitleCompanion = companion.hasPersistentData ? companion : nil
    }
}
