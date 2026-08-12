# 本地化（两张表 + 应用内语言切换）

界面语言有三种：跟随系统、English、简体中文。文案只有两张表：
`Sources/SrtFlow/Resources/en.lproj/Localizable.strings`（恒等，填原文）和
`zh-Hans.lproj/Localizable.strings`（译文）。

本文只写**长期约束**。实现在 `Sources/SrtFlow/AppLanguage.swift`。

## 一、写死的界面文案必须两张表都有（守卫钉着）

**查不到不是错误，是静默降级**：不报错、不崩，只是在中文界面里原样显示英文。
编译器发现不了，代码审查也发现不了 —— 只有中文用户挨个点过去才看得见。
2026-08-12 用户报了几条英文 tooltip，一扫发现 132 条文案从没进过表
（见 [案例](../bugfixes/2026-08-12-instant-tooltip-first-show-far-off.md)）。

`scripts/check-localization-coverage.sh` 扫全部源码，第一个实参是
`LocalizedStringKey` 的调用一个不落：`Text` / `Label` / `Button` / `Toggle` /
`Picker` / `TextField` / `Section` / `Stepper` / `Menu` / `Link` /
`confirmationDialog` / `.alert` / `.navigationTitle` / `LocalizedStringKey(…)` /
`instantHelp` / `ToolbarIcon(help:)`，外加代码里查表的 `L10n(…)`。
**新增 SwiftUI 控件类型时要往守卫的清单里补一行**，漏一个就是漏一类文案。

守卫是用 Swift 写的，不是 grep：调用点经常换行（`Label(\n    "…"`），文档注释里
又常写着示例代码 —— 行扫描要么漏掉前者，要么把后者当成真文案。

两处**已知盲区**，不是漏网，必须人工确认：

- **带插值的键**（`Text("已选 \(n) 段")`）真实键要到运行期才成形（`%lld` / `%@`），
  静态扫不出来。
- **豁免清单**（单位、符号、示例字、App 名）写在
  `checks/LocalizationCoverage/main.swift` 的 `exempt` 里。往里加东西之前，先能
  说出「它为什么在任何语言下都长一样」—— 说不出来就是该翻。

## 二、`L10n(…)` 与 `Text(LocalizedStringKey)` 分工

- **SwiftUI 里的文案**用 `Text("…")` 这类字面量，跟着环境 locale 走，切语言立刻变。
- **代码里拼字符串**（错误描述、`String(format:)`、NSPanel 的 prompt）用 `L10n("…")`：
  `NSLocalizedString` 只认系统语言，不认应用内的选择。`L10n` 读的是
  `LanguageSnapshot`，一份不受 actor 约束的快照 —— 因为它会在后台线程被求值。
- **运行期算出来的字符串**（路径、素材名、用户输入）走 `Text(verbatim:)` /
  `instantHelp(_ text: some StringProtocol)`，**绝不查表**：拿用户的文件名当本地化
  键去查，是另一种事故。

## 三、应用内切换语言的两个坑

1. **SwiftPM 会把本地化目录名转小写**（`zh-Hans.lproj` → `zh-hans.lproj`），而
   `Bundle.path(forResource:ofType:)` 区分大小写。直接拿语言代码去查会落空、
   悄悄退回英文。`AppLanguage.bundle` 因此先在 `Bundle.main.localizations` 里做
   不区分大小写的匹配。
2. **菜单栏、文件选择面板这些 AppKit 部件只认启动时的 `AppleLanguages`**，切完要
   重启才一致。界面上据此提示（`AppLanguageStore.needsRestartForMenus`）。

## 四、加新文案的流程

1. 代码里写 `LocalizedStringKey` 字面量（或 `L10n("…")`）。
2. **同时**补进 `en.lproj`（恒等）和 `zh-Hans.lproj`（译文）。
3. 跑 `scripts/check-localization-coverage.sh`。
4. 键里带插值的，守卫看不见，自己核对表里的 `%lld` / `%@` 形态对不对。

## 五、人工回归清单

- 切到简体中文，走一遍这次改动的界面：不该有英文残留。
- 显示路径、素材名、用户输入的地方保持原样，不被当成键翻译。
- 切换语言后重启一次，菜单栏也跟着变。
