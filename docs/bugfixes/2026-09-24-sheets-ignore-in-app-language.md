# 2026-09-24 应用里选了简体中文，所有 sheet 和 popover 却还是英文

## 症状

系统语言是英文、应用内语言选「简体中文」时，主窗口全是中文，但**弹出来的 sheet 和
popover 里写死的文案一律是英文**：导出面板的「Export Video / Title / Resolution /
Advanced / Close」，字幕生成面板、录屏设置页、录屏恢复提示、音乐来源、字体列表、转场
选择器、标记编辑、字幕就地编辑……同一张面板里，走 `L10n(…)` 拼出来的那几句（「跟随
工程（1920×1080）」「这个文件夹里已经有……」）又是中文，于是半中半英。

系统语言本身是中文的用户看不到这个问题：查表退回系统语言，碰巧也是中文。

导出面板改版后在中文界面里做 GUI 冒烟时看到的。

## 根因

应用内语言的做法是在两个场景（主窗口、设置）的根上套 `.appLanguage()`，往环境里注入
`\.locale`；SwiftUI 的 `Text("…")` 按环境的 locale 查表。

**SwiftUI 不把 `\.locale` 带进 sheet 和 popover。** 写了个探针定性（macOS 26）：窗口根上
注入 `zh-Hans`，窗口里读到 `zh-Hans`，同一个窗口弹出的 popover 和 sheet 里读到的都是
`en_US`（系统语言）。它们是新的宿主窗口，环境只带了一部分过去。

自建的 `NSHostingView` 更不用说 —— 它本来就是一个新的根。仓库里两处：即时提示的面板
早就套了 `.appLanguage()`（2026-08-12 那一轮），录屏控制窗的没有。

`L10n(…)` 不受影响，因为它读的是 `LanguageSnapshot`，不看环境 —— 这正是「半中半英」的
来历。

## 修复

- 6 个 sheet、6 个 popover 的内容，以及录屏控制窗的 `NSHostingView`，都在内容的根上套
  `.appLanguage()`（它就是给环境注入 locale，重复套一次无害）。
- 新扫描守卫 `checks/presented-views-app-language.sh`（进了 `scripts/check-all.sh` 第 1 组）：
  每个 `.sheet(` / `.popover(` 的内容、每个 `NSHostingView(` / `NSHostingController(` 的参数里
  都必须出现 `appLanguage()`，否则红。括号配不上（认不出的写法）也红，不许静默跳过；
  一处都没扫到也红。

## 验证

- 探针：修复前的写法就是「窗口 zh-Hans、sheet / popover en_US」。
- GUI 冒烟（中文界面、真实窗口）：导出面板全中文（导出视频 / 标题 / 导出至 / 分辨率 /
  高级 / 关闭 / 导出），同名确认框也是中文（替换「L12.mp4」？/ 取消 / 替换）。
- 守卫反向验证：去掉导出面板那一处 `.appLanguage()` → 红在 `VideoEditView.swift:123`；
  去掉录屏控制窗那一处 → 红在 `ScreenRecordingControlPanel.swift:67`；恢复后 14 处全绿。

## 教训 / 防回归

1. **「环境值会自动往下传」对 sheet / popover 不成立**，至少 `\.locale` 不成立。凡是新的
   宿主（sheet、popover、自建的 `NSHostingView`），都要自己把应用内语言套上。长期约束写进
   [本地化](../architecture/localization.md)。
2. 本地化的冒烟要在「系统英文 + 应用中文」这个组合下做。系统本身是中文时，查表退回系统
   语言也是中文，问题整个被盖住。
3. 冒烟时自己拼的调试拷贝要照 `build-app.sh` 把 `*.lproj` 平铺进 `Contents/Resources`，
   不然哪种设置都只有英文（见 [GUI 冒烟流程](../testing/gui-smoke-testing.md)）。
