# 本地化（两张表 + 应用内语言切换）

界面语言有三种：跟随系统、English、简体中文。文案只有两张表：
`Sources/SrtFlow/Resources/en.lproj/Localizable.strings`（原文）和
`zh-Hans.lproj/Localizable.strings`（译文）。

**键是标识符，值才是显示文案。** en 表绝大多数是恒等（键就是英文原文），但键撞车
或英文要显示成缩写时，键与值可以不同 —— 现有的几条：`"Left" = "L"`、
`"Right" = "R"`、`"Top" = "T"`、`"Bottom" = "B"`、`"Font size" = "Size"`。

本文只写**长期约束**。实现在 `Sources/SrtFlow/AppLanguage.swift`。

## 一、写死的界面文案必须两张表都有（守卫钉着）

**查不到不是错误，是静默降级**：不报错、不崩，只是在中文界面里原样显示英文。
编译器发现不了，代码审查也发现不了 —— 只有中文用户挨个点过去才看得见。
2026-08-12 用户报了一条英文 tooltip，顺着扫下去共 **194 条**文案从没进过表
（73 条按钮提示 + 108 条界面文案 + 13 条藏在动态 key 后面的），
见 [案例](../bugfixes/2026-08-12-instant-tooltip-first-show-far-off.md)。

`scripts/check-localization-coverage.sh` 扫全部源码，第一个实参是
`LocalizedStringKey` 的调用一个不落：`Text` / `Label` / `Button` / `Toggle` /
`Picker` / `TextField` / `Section` / `Stepper` / `Menu` / `Link` /
`confirmationDialog` / `.alert` / `.navigationTitle` / `LocalizedStringKey(…)` /
`instantHelp` / `ToolbarIcon(help:)`，外加代码里查表的 `L10n(…)`。
还包括经参数转交的（`ToolbarIcon(help:)`、`LabeledSlider(label:)`）和
`String(localized:)`。**新增 SwiftUI 控件类型、或新开一个转交文案的参数标签时，
要往守卫的清单里补一行**，漏一个就是漏一类文案 —— `help:` 和 `label:` 都是这么
漏过一轮的。

守卫是用 Swift 写的，不是 grep：调用点经常换行（`Label(\n    "…"`），文档注释里
又常写着示例代码 —— 行扫描要么漏掉前者，要么把后者当成真文案。

### 动态 key 也扫

`L10n(section.title)`、`LocalizedStringKey(kind.title)` 这种键不写在调用点，而是某个
属性算出来的。守卫先从调用点收集用到的属性名（`title`、`blurb`、`displayName`…），
再把这些名字的**计算属性体**里的字面量当成 key —— 否则这一整类都是假绿：把表里对应
的条目全删掉，守卫照样全绿。

### 三条兜底

1. **两张表的键集必须完全相同**（这是最有用的一条：静态扫不到的键，只要有人只往
   一张表里加，立刻红）。
2. **译文不许为空**（空串在界面上就是一片空白，比留着英文还糟）。
3. **占位符必须两张表一致**：`String(format:)` 按格式串取参数，译文少一个 `%@` 就
   内容错位，多一个就去读没传的参数、**直接崩**。按出现顺序比，所以 `%d, %@` 写成
   `%@, %d` 也会红。
   守卫**抓不住**两个同类型占位符对调（`%@ … %@` 调完序列一模一样，静态分辨不出）
   —— 所以**要换语序就用带位置的 `%1$@` / `%2$@`**，那是唯一能安全重排的写法。

### 一个键只能有一个含义

同一张表里写两遍同一个键，**解析器不报错**，后面那条静静盖掉前面那条 ——
表现为「明明翻译过了，界面上显示的却是另一个词」。实测踩过：`"Size"` 在样式编辑里
是「字号」、在画中画里是「大小」，于是字号那处显示成了「大小」。

撞车时把其中一处的键改具体（`"Font size"`），**英文显示文案可以保持原样**（en 表里
写 `"Font size" = "Size"`）。守卫扫两张表的重复键。

### 已知盲区

三处，是**明写出来的盲区**，不是漏网；这几类要人工确认，键集一致那条兜底也能挡住
一部分：

- **带插值的键**（`Text("已选 \(n) 段")`）真实键要到运行期才成形（`%lld` / `%@`），
  静态扫不出来。
- **存储属性里的 key**（`item.title` 是构造时赋的值，不是计算属性）求值才知道。
- **豁免清单**（单位、符号、示例字、App 名、语言选择器的三个选项）写在
  `checks/LocalizationCoverage/main.swift` 的 `exempt` 里。往里加东西之前，先能
  说出「它为什么在任何语言下都长一样」—— 说不出来就是该翻。

技术标识（`1080p`、`24 fps`、`SRT`、x264 的 `medium`）**进表走恒等**，不进豁免清单：
进表是数据，以后想改随时能改；进豁免清单就成了守卫的盲点。

## 二、`L10n(…)` 与 `Text(LocalizedStringKey)` 分工

- **SwiftUI 里的文案**用 `Text("…")` 这类字面量，跟着环境 locale 走，切语言立刻变。
- **代码里拼字符串**（错误描述、`String(format:)`、NSPanel 的 prompt）用 `L10n("…")`：
  `NSLocalizedString` 只认系统语言，不认应用内的选择。`L10n` 读的是
  `LanguageSnapshot`，一份不受 actor 约束的快照 —— 因为它会在后台线程被求值。
- **运行期算出来的字符串**（路径、素材名、用户输入）走 `Text(verbatim:)` /
  `instantHelp(_ text: some StringProtocol)`，**绝不查表**：拿用户的文件名当本地化
  键去查，是另一种事故。
- **不要用 `String(localized:)`**：它只认系统语言，不认 App 内的语言选择 —— 系统是
  英文、App 切成中文时，那一句会留在英文。要在代码里查表就用 `L10n`。

### 自己写「收文案」的 API 时：两个重载会互相抢

给自定义修饰符/组件同时提供 `LocalizedStringKey` 和 `some StringProtocol` 两个重载，
**字符串字面量会优先选 `String` 那条**（默认字面量类型胜出），于是所有写死的文案
悄悄绕过查表。`instantHelp` 栽过一次，全 App 的提示因此在译文补齐后仍是英文。

两个可行解：给不查表的那条加参数标签（`instantHelp(verbatim:)`，本仓库的做法），
或给它加 `@_disfavoredOverload`（系统 `.help` 的做法）。**只留一个重载也行**。
不要指望「非泛型更特化所以会赢」—— 实测不会。

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
