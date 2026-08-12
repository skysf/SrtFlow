import Foundation
import SrtFlowCore

// formatVersion 的登记清单。原始机制是「按需写入」
//（docs/plans/2026-08-06-native-subtitle-generation.md 7.4）：writer 只在真的
// 存在高版本 only 数据时才抬版本，版本闸门只对真正用了新功能的工程关门。
// v5（工程帧率）起这个机制被无条件要求覆盖 —— 每个工程都有帧率，所以 writer
// 一律写 latest。下面的判据保留为**登记清单**：加新字段时先在这里回答
// 「旧版拿到它会不会毁数据」，答案为是就开一个新版本号。
// 长期约束见 docs/architecture/video-edit-project-file.md。

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

    /// 是否存在「旧版打开会被静默丢掉」的 v6-only 持久数据。
    ///
    /// **登记清单（新增 v6-only 字段必须同步补进来）：**
    /// 1. `subtitleLayout` —— 工程级字幕布局覆盖（位置 / 换行宽度 / 字号倍率）。
    /// 2. `subtitleHidden` —— 字幕轨的眼睛。
    ///
    /// 两个字段都是 2026-08-09 那批字幕轨 UX 加进 `TimelineState` 的，但当时
    /// 没升版本。后果是标准的「旧版静默毁数据」：只认 v5 的旧版照常打开新工程，
    /// 用户随手编辑一下触发自动保存，布局就被删光 —— 字幕位置/宽度/字号连同
    /// **导出画面**一起变回默认，而 `subtitleHidden` 被抹掉还会让本该隐藏的
    /// 字幕重新烧进成片。判断标准见
    /// docs/bugfixes/2026-08-04-transform-review.md：问的不是「新版能不能读
    /// 旧文件」，而是「旧版拿到新文件会不会毁数据」。
    ///
    /// 注意 `subtitleHidden` 无条件落盘（Codable 里是 `encode` 不是
    /// `encodeIfPresent`），所以这个判据恒为真；`subtitleLayout` 仍按需写键。
    /// 判据本身保留是为了登记清单的可读性 —— writer 的定版已被 v5 的无条件
    /// 要求接管（一律写 latest）。
    var requiresFormatVersion6: Bool { true }

    /// 是否存在「旧版打开会被静默丢掉」的 v7-only 持久数据。
    ///
    /// **登记清单（新增 v7-only 字段必须同步补进来）：**
    /// 1. `translationHidden` —— 译文字幕轨的眼睛。
    ///
    /// 为什么要升版本：改成「一个语言一条轨」之后，**烧录跟着眼睛走** ——
    /// 这个键直接决定成片里有没有译文。只认 v6 的旧版打开后自动保存会把它
    /// 删掉，用户「只烧中文」的意图就变回默认值，成片跟着变。
    /// 判据同 `requiresFormatVersion6`：无条件落盘，恒为真。
    var requiresFormatVersion7: Bool { true }

    /// 是否存在「旧版打开会被静默丢掉」的 v8-only 持久数据。
    ///
    /// **登记清单（新增 v8-only 字段必须同步补进来）：**
    /// 1. `EditClip.markers` —— 轨道块上的标记（位置 / 颜色 / 备注文字）。
    ///
    /// 标记不进合成也不进导出，成片一帧都不会变 —— 但版本闸门问的从来不是
    /// 「成片会不会变」，而是「旧版拿到新文件会不会毁数据」。只认 v7 的旧版
    /// 照常打开，用户随手编辑触发自动保存，整份标记连同备注文字一起被抹掉，
    /// 而这是纯手工输入、丢了只能重标一遍的数据。
    ///
    /// 这条按 v4 的**按需**写法（标记表是空的就不算 v8 数据），不像 v5–v7 那样
    /// 恒为真：没打过标记的工程本来就没有 v8 语义。writer 的定版仍被 v5 的
    /// 无条件要求接管（一律写 latest），这里保留为登记清单。
    var requiresFormatVersion8: Bool { hasClipMarkers }

    /// 是否存在「旧版打开会被静默丢掉」的 v9-only 持久数据。
    ///
    /// **登记清单（新增 v9-only 字段必须同步补进来）：**
    /// 1. `EditClip.fadeInDuration` / `fadeOutDuration` —— 声音的渐入渐出时长。
    ///
    /// 为什么要升版本：这两个键**直接决定成片里的声音**。只认 v8 的旧版照常
    /// 打开，用户随手编辑触发自动保存就把它们删光 —— 调好的渐入渐出没了，
    /// 导出的音频跟着变（开头结尾从渐变变成硬切）。判断标准同
    /// docs/bugfixes/2026-08-04-transform-review.md：问的不是「新版能不能读
    /// 旧文件」，而是「旧版拿到新文件会不会毁数据」。
    ///
    /// 按 v4/v8 的**按需**写法（没设过渐变的工程不算 v9 数据），
    /// 与 `EditClip` 的 Codable 只在 `> 0` 时写键一致。writer 的定版仍被
    /// v5 的无条件要求接管（一律写 latest），这里保留为登记清单。
    var requiresFormatVersion9: Bool { hasAudioFades }

    /// 读盘后的规范化：companion 的译文轨/cueMeta 必须锚在现有原文 cue 上，
    /// 对不上的是坏数据（外部改动、半截文件），静默清掉而不是带病运行。
    mutating func normalizeSubtitleCompanion() {
        guard var companion = subtitleCompanion else { return }
        let ids = Set((subtitle?.cues ?? []).map(\.id))
        companion.normalize(originalCueIDs: ids)
        subtitleCompanion = companion.hasPersistentData ? companion : nil
    }
}
