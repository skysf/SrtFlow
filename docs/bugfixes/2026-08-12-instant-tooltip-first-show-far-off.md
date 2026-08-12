# 2026-08-12 提示第一次弹在很远的地方，还有一批提示没翻成中文

## 症状

用户实测（中文界面，视频编辑页）：

1. **位置**：鼠标第一次放到工具栏的「鼠标工具」按钮上，提示气泡出现在控件**下方
   几百点**的地方（截图里几乎贴到预览画布的左下角）；移开再放一次，位置就正常了。
2. **文案**：那条提示写着 `Mouse tool: Select or Split` —— 界面其它部分都是中文，
   只有一批提示是英文。

## 根因

两件独立的事，都出自 2026-08-10 的即时提示改造（PR #28）。

### 一、`NSHostingView` 直接当 `NSPanel.contentView`

`InstantTooltipController.show` 原本是：量出 `hosting.fittingSize` → 把 hosting
挂成面板的 `contentView` → `setFrame` 摆到控件正下方 → `orderFront`。

摆位算得没错，**摆完之后面板自己变了**。`NSHostingView` 会把自己的尺寸约束灌成
所在窗口的 `contentMinSize` / `contentMaxSize`，实测一条 24pt 高的提示报出来的是
`contentMinSize = (30, 332)`；AppKit 下一轮排版就把面板撑到 332 高，而气泡在
面板里垂直居中 —— 于是气泡落到了控件下方一百多点的位置。探针实测：

```
摆位后 = (500, 600, 155,  24)
稳定后 = (500, 292, 155, 332)   ← 上屏时保住上边、向下长
稳定后 = (500, 600, 155, 332)   ← 未上屏时保住下边、向上长
```

「第二次就正常了」没有单独复现过。已知的是：被撑成的高度**随内容而变**（换一条
更短的提示，实测撑到的是 220 而不是 332），而气泡在面板里垂直居中，所以偏移量
本身是浮动的 —— 第二次看着正常，最可能就是这次偏移量正好落回控件附近。
**这也是这个 bug 最难被发现的地方：同一个缺陷每次错得不一样多，用户只会记得
「第一次不对」，而按「第一次/第二次」去找原因永远找不到。**

### 二、提示文案根本没进字符串表

`instantHelp("…")` 的字面量是 `LocalizedStringKey`，查不到就**原样显示英文**，
不报错也不崩。改造一次性新增/改写了 70 多条提示文案，`Localizable.strings` 两张表
都没跟着补，所以中文界面下这些提示全是英文。旧的键（`Mouse tool: Select (A) or
Split (B)` 之类）还留在表里，看上去「翻译过了」，其实调用点早就换了文案。

漏网的还不止一种写法：工具栏那一整排走的是 `ToolbarIcon(help: "…")`，播放/暂停和
渐入/渐出走的是三目里的 `LocalizedStringKey("…")`。只按 `.instantHelp("` 找，会
漏掉一大半。

## 修复

- `Sources/SrtFlow/InstantTooltip.swift`：hosting 外面垫一层普通 `NSView` 再挂成
  `contentView`，面板尺寸就只由 `setFrame` 说了算。同时加了一个
  `panelFrameForChecks` 只读口子给自检量落点。
- `Sources/SrtFlow/Resources/{en,zh-Hans}.lproj/Localizable.strings`：补齐 73 条
  提示文案（en 恒等、zh-Hans 译文），删掉 6 条改造后已失效的旧键
  （`Split at playhead (⌘B)` 这类带括号快捷键的写法）。
- 顺着这条线把**全仓库**扫了一遍，另有 108 条界面文案（录屏面板与全部失败原因、
  工程菜单与文档提示、标记与导出）也从没进过表，一并补齐。合计 181 条。
- 新增 `checks/LocalizationCoverage/`（Swift）+ `scripts/check-localization-coverage.sh`：
  把「写死的文案必须两张表都有」升成**全局**守卫，长期约束写进
  [本地化](../architecture/localization.md)。提示那一类不再单独维护一份规则。

## 验证

- `scripts/check-instant-tooltip-panel.sh`（新增）：拿真实的
  `InstantTooltipController.show` 对已知位置的锚点弹提示，量面板真实落点。
  9 条断言全绿。
  **反向验证**：把 hosting 改回直接当 contentView，9 条里红 6 条、退出码 1：
  ```
  FAIL 面板摆好之后不许自己改尺寸/挪位置：摆位 (335, 1493, 192, 25) → 稳定 (335, 1186, 192, 332)
  FAIL 单行提示的面板高度不该超过 60：实际 332
  FAIL 下方放不下时要翻到控件上方：期望 926，实际 619
  ```
- `scripts/check-localization-coverage.sh`（新增）：434 条界面文案在两张表里都有。
  **反向验证**：删掉 zh 表里 `Start Recording` 一行 → `FAIL zh-Hans 表里没有：
  "Start Recording" ← Sources/SrtFlow/ScreenRecordingSetupView.swift:114`，退出码 1；
  补回去退出码 0。（第一版守卫用 grep 写，漏掉换行写的调用，已改用 Swift 扫描。）
- `plutil -lint` 两张表都 OK；`swift build --arch arm64` 通过。
- hover 本身没法自动化（`.onHover` 对合成鼠标事件不响应，见
  [GUI 冒烟流程](../testing/gui-smoke-testing.md)），所以「鼠标一放上去」这一段
  仍按 [即时提示](../architecture/instant-tooltips.md) 的人工清单实机过。

## 教训 / 防回归

1. **摆好 ≠ 摆定。** 算完位置就以为完事了，是这次的思维盲点 —— 面板是在
   `setFrame` 之后的下一轮排版里被 AppKit 改掉的。凡是自己给窗口摆位的地方，
   自检都要**跑一轮 runloop 再量一次**，只量「刚摆完」等于没量。
2. **SwiftUI 的宿主视图不能直接交给窗口当 contentView**，它会把布局意图当成
   窗口的尺寸约束。长期约束写进
   [即时提示](../architecture/instant-tooltips.md#五面板自己的硬约束守卫钉着)。
3. **本地化查不到是静默降级**：不报错、不崩、只是显示英文，代码审查和编译都发现
   不了，只有中文用户挨个划过按钮才看得见。新增任何 `LocalizedStringKey` 文案都必须
   同步两张表，现在由全局守卫钉着（见 [本地化](../architecture/localization.md)）。
   **用户报了一处，就该去数还有多少处** —— 这次报回来 1 条，实扫出 181 条。
4. 这条 bug 出在「加了守卫的功能」上：`checks/instant-tooltip-wiring.sh` 当时只钉了
   接线（不许用 `.help`、快捷键单一来源），没钉**结果**（提示最终落在哪、写的是哪种
   语言）。**守卫要盯用户看得见的那一面，不能只盯代码写法。**
