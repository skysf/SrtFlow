# 2026-09-26 分割一段藏起来的素材，右半段冒回成片；音频库素材分割后右半段丢了身份

## 症状

写时间线复制粘贴时读分割的代码发现的（用户没报过）：

- 选中一段按 V 藏起来，再在它中间切一刀：左半还藏着，**右半段变回显示** —— 进预览，也进成片。
- 从音频库拖进来的音乐切一刀：右半段没有了音频库的 manifest 键（`remoteKey`）。当下能播；等缓存被清、
  或者工程发给别人，右半段就**永久失链**，而且没人知道原来是哪一首（左半还能从 R2 拉回来）。

## 根因

`TimelineState.split` 手写构造右半段：用 `EditClip` 的逐字段构造器照抄左半的字段，再补上构造器里没有的几个
（`needsStillConversion`、`markers`、`volumeCurve`、`soundScene`）。后来加进 `EditClip` 的两个字段没人补进来：

- `remoteKey`（2026-09-22，音频库）：构造器里有这个参数，这里没传 —— 取了默认值 nil；
- `isHidden`（段的隐藏，V）：不在构造器里，这里也没补 —— 取了默认值 false。

编译器一声不吭：两个都有默认值。自检也没钉 —— 分割的用例只查了时间、标记、音量曲线、声音场景。

这和 [框选加选丢了滤镜段](2026-09-25-marquee-additive-drops-filters.md) 是同一类：**带默认值的字段 + 手写逐字段
构造，加字段时漏一处没人知道**。

## 修复

- `split` 右半段带上 `remoteKey`，并补一行 `right.isHidden = left.isHidden`。
- 复制粘贴那一路**不手写**：每一样粘出来都是「编码 → 换掉顶层 `id` → 解回来」（`ClipboardIdentity.renewed`，
  [复制粘贴](../architecture/timeline-clipboard.md)），存盘编码里有的字段一个都不会漏。
- 为了在 `VideoEditTimelineEdits.swift`（登记过的超标老文件，只许降）里放下这几行，把「主轨上哪儿牵扯着转场」
  的两条判据（`participatesInMainTransition` / `isInsideMainTransition`）挪到了它们依赖的
  `VideoEditTransitionHandles.swift`（每个编前者的自检都编着后者）。

## 验证

- `scripts/check-timeline-clipboard.sh` 第 4 组：藏着、带音频库键的一段切开，两半都藏着、都带着键。
  **反向验证**：撤掉这两处修复 → 红两条（`[true, false]`、`[library-42, nil]`）；恢复转绿。

## 教训 / 防回归

- **从旧段构造新段的地方（分割、定格、复制），加字段时都要过一遍。** 工程文件的架构文档早就写着「图片段的身份
  要在复制路径上跟着走」，这次是另外两个字段栽在同一个坑里。能不手写就不手写（复制粘贴走编码往返）。
- 分割的自检要覆盖「段自己的标记」：隐藏、音频库的键，以后再加字段（能改成片或能重链接的）同样补一条。
