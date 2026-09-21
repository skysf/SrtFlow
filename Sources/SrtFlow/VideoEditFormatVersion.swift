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

    /// 是否存在「旧版打开会被静默丢掉」的 v10-only 持久数据。
    ///
    /// **登记清单（新增 v10-only 字段必须同步补进来）：**
    /// 1. `EditClip.videoFadeInDuration` / `videoFadeOutDuration` —— 画面的
    ///    渐入渐出时长。
    /// 2. **上层视频轨的默认摆放语义**（不是某个键，是 `placement == nil` 的
    ///    含义变了）。
    /// 3. `EditLane.colorIndex` —— 轨道颜色。
    ///
    /// 为什么无条件为真：第 2 条不是可选数据，而是一次**语义换代**。
    /// 2026-09-17 起上层视频轨不再是画中画 —— `placement == nil` 从「按
    /// `overlayFraction`/`overlayAnchor` 停在右上角的小框」改成「等比铺满居中」，
    /// 而那两个键已经删了。只认 v9 的旧版照常打开新工程，上层轨的每一段都会
    /// 变回 40% 宽的角落小窗，**成片当场就不一样**；用户随手编辑触发自动保存，
    /// 画面渐变和轨道颜色再一起被抹掉。判断标准同
    /// docs/bugfixes/2026-08-04-transform-review.md：问的不是「新版能不能读旧
    /// 文件」，而是「旧版拿到新文件会不会毁数据」。
    ///
    /// 所以这条走 v5–v7 的**无条件**写法，不像 v4/v8/v9 那样按需 —— 任何一份
    /// 带上层视频轨的新工程都有 v10 语义，而「有没有上层轨」不该由用户去猜。
    /// writer 的定版仍被 v5 的无条件要求接管（一律写 latest），这里保留为登记清单。
    var requiresFormatVersion10: Bool { true }

    /// 是否存在「旧版打开会被静默丢掉」的 v11-only 持久数据。
    ///
    /// **登记清单（新增 v11-only 字段必须同步补进来）：**
    /// 1. `TimelineState.textOverlays` —— 画面上的文字标注（连同它的
    ///    `TextStyle`：字体、填充/渐变、描边、投影、底板、对齐、行距、字距）。
    ///
    /// 走 v4/v8/v9 的**按需**写法：没有文字的工程不带 v11 数据，也就不该被抬
    /// 进 v11（`TimelineState.encode` 里空数组不落盘，两处必须一致）。判断标准
    /// 同 docs/bugfixes/2026-08-04-transform-review.md：问的不是「新版能不能读
    /// 旧文件」，而是「旧版拿到新文件会不会毁数据」——
    /// 只认 v10 的旧版打开带文字的工程，`textOverlays` 这个键它不认识，
    /// 画面上的字**当场消失**；用户随手编辑触发自动保存，这段文字就永久没了。
    ///
    /// writer 的定版仍被 v5 的无条件要求接管（一律写 latest），这里保留为
    /// 登记清单。
    var requiresFormatVersion11: Bool { !textOverlays.isEmpty }

    /// 是否存在「旧版打开会被静默丢掉」的 v12-only 持久数据。
    ///
    /// **登记清单（新增 v12-only 字段必须同步补进来）：**
    /// 1. `TextOverlay.animation` —— 文字的入场 / 出场 / 强调动画。
    ///
    /// 同样是**按需**：没设动画的文字不落 `animation` 键
    ///（`TextOverlay.encode` 里 `isEmpty` 时跳过），两处必须一致。
    ///
    /// 为什么带动画就必须抬：只认 v11 的旧版不认识这个键，打开之后文字会变成
    /// **硬切出现**——入场的那一下正是标题最显眼的地方，成片当场就不一样；
    /// 随手编辑触发自动保存，调好的动画就永久没了。判断标准同
    /// docs/bugfixes/2026-08-04-transform-review.md。
    var requiresFormatVersion12: Bool {
        textOverlays.contains { !$0.animation.isEmpty }
    }

    /// 是否存在「旧版打开会被静默丢掉」的 v13-only 持久数据。
    ///
    /// **登记清单（新增 v13-only 字段必须同步补进来）：**
    /// 1. `TextOverlay.number` —— 数字滚动（起止值、小数位、千分位、前后缀、
    ///    形态、滚动时长）。
    ///
    /// 同样是**按需**：普通文字不落 `number` 键，两处必须一致。
    ///
    /// 为什么带数字就必须抬：只认 v12 的旧版不认识这个键，那一段会退回显示
    /// `text` 字段 —— 而数字元件的 `text` 是空的，于是画面上**整段消失**。
    /// 随手编辑触发自动保存，配好的数字就永久没了。
    var requiresFormatVersion13: Bool {
        textOverlays.contains { $0.number != nil }
    }

    /// 是否存在「旧版打开会被静默丢掉」的 v14-only 持久数据。
    ///
    /// **登记清单（新增 v14-only 字段必须同步补进来）：**
    /// 1. `TextAnimationKind.focus` —— 对焦（边放大边从模糊收清）。
    /// 2. `TextAnimation.focusStartOpacity` —— 对焦起手/收尾的不透明度。
    ///
    /// **新增的枚举值也算持久数据。** `TextAnimationKind` 是宽容解码的
    /// （`LenientCodableEnum`，不认识就退回 `.none`），这正是危险所在：
    /// 只认 v13 的旧版打开之后，那一段的入场/出场**静默变成"无动画"**，
    /// 标题最显眼的那一下当场没了；随手编辑触发自动保存就永久丢失。
    /// 判断标准同 docs/bugfixes/2026-08-04-transform-review.md —— 问的不是
    /// 「新版能不能读旧文件」，而是「旧版拿到新文件会不会毁数据」。
    ///
    /// 按需：没用到对焦的工程不带 v14 数据
    ///（`TextAnimation.encode` 里 `usesFocus` 为假时不落那个键，两处一致）。
    var requiresFormatVersion14: Bool {
        textOverlays.contains { $0.animation.usesFocus }
    }

    /// 是否存在「旧版打开会被静默丢掉」的 v15-only 持久数据。
    ///
    /// **登记清单（新增 v15-only 字段必须同步补进来）：**
    /// 1. `EditClip.presetAnimation` —— 画面段的入场 / 出场动画
    ///    （效果 + 强度；时长复用 v10 就有的 `videoFade*`）。
    ///
    /// **按需，而且只认非 `.fade` 的效果**：`.fade` 落的就是 v10 的那两个时长键，
    /// 旧版读得懂、渲出来一模一样，抬版本纯属误伤（用户只是设了个淡入，工程却
    /// 再也回不去旧版）。其余几种要逐帧变换/裁切，旧版不认识 `presetAnimation`
    /// 这个键，那一段会**静默变回硬切或纯淡入** —— 入场那一下正是画面最显眼的
    /// 地方，成片当场就不一样；随手编辑触发自动保存，调好的动画就永久没了。
    /// 判断标准同 docs/bugfixes/2026-08-04-transform-review.md。
    ///
    /// 与 `EditClip.encode` 的按需写键必须同源：那边判的是 `isEmpty`
    /// （效果全是 `.none` 才不写），这边判的是"有没有非 fade 的效果"——
    /// 只设了 `.fade` 的段照样落键（强度也跟着存下来），但不抬版本。
    var requiresFormatVersion15: Bool {
        allClips.contains { clip in
            clip.presetAnimation.entrance.needsPerFrameRender
                || clip.presetAnimation.exit.needsPerFrameRender
        }
    }

    /// 是否存在「旧版打开会被静默丢掉」的 v16-only 持久数据。
    ///
    /// **登记清单（新增 v16-only 字段必须同步补进来）：**
    /// 1. `EditClip.isHidden` —— 单段隐藏（快捷键 V）。
    ///
    /// 为什么要升版本：这个键直接决定**成片里有没有这一段**。只认 v15 的旧版
    /// 不认识它，打开后那几段会原样出现在预览和导出里 —— 用户藏起来的镜头当场
    /// 回到成片；随手编辑触发自动保存，标记就被永久抹掉，他得重新一段段找出来
    /// 再藏一遍。判断标准同 docs/bugfixes/2026-08-04-transform-review.md。
    ///
    /// **按需**：没有任何段被隐藏的工程不带 v16 数据（`EditClip.encode` 里
    /// `isHidden` 为假时不落那个键，两处必须同源）。所以没用过 V 的工程照旧
    /// 能被旧版打开。
    var requiresFormatVersion16: Bool {
        allClips.contains { $0.isHidden }
    }

    /// 是否存在「旧版打开会被静默丢掉」的 v17-only 持久数据。
    ///
    /// **登记清单（新增 v17-only 字段必须同步补进来）：**
    /// 1. `filters` —— 时间轴上的调色段（种类 / 强度 / 起止 / 叠加层号）。
    ///
    /// 为什么要升版本：这些键直接决定**成片是什么颜色**。只认 v16 的旧版不认识
    /// 它们，打开后整条片子退回原色；随手编辑触发一次自动保存，调好的色就被
    /// 永久抹掉了。判断标准同 docs/bugfixes/2026-08-04-transform-review.md：
    /// 问的不是「新版能不能读旧文件」，而是「旧版拿到新文件会不会毁数据」。
    ///
    /// **按需**：没有滤镜段的工程不带 v17 数据（`TimelineState.encode` 里空数组
    /// 不落键，两处必须同源），所以没用过滤镜的工程照旧能被旧版打开。
    var requiresFormatVersion17: Bool { !filters.isEmpty }

    /// 读盘后的规范化：companion 的译文轨/cueMeta 必须锚在现有原文 cue 上，
    /// 对不上的是坏数据（外部改动、半截文件），静默清掉而不是带病运行。
    mutating func normalizeSubtitleCompanion() {
        guard var companion = subtitleCompanion else { return }
        let ids = Set((subtitle?.cues ?? []).map(\.id))
        companion.normalize(originalCueIDs: ids)
        subtitleCompanion = companion.hasPersistentData ? companion : nil
    }
}
