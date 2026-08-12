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

### 三、同一个键写了两遍：`"Size"`

补齐文案时顺手撞见的第三件事，同一类：`"Size"` 在两张表里各出现两次 ——
样式编辑里是「字号」（第 146 行），画中画里是「大小」（第 247 行）。

**plist 解析器不会报错**，后面那条静静盖掉前面那条，所以样式编辑的字号滑块在中文
界面里一直显示成「大小」。这比「没翻译」更隐蔽：文案明明在表里、明明翻译过了，
只是显示成了另一个词。

改法：把样式编辑那处的键改成更具体的 `"Font size"`，**英文显示文案保持 `Size` 不变**
（`"Font size" = "Size"`）—— 仓库里本来就有 `"Left" = "L"`、`"Right" = "R"` 这种
「键是标识符、值才是显示文案」的先例。

`LabeledSlider(label: "…")` 这类经参数转交的文案，守卫原先也看不见（和当初漏掉
`ToolbarIcon(help:)` 是同一个洞），一并补进扫描；`DispatchQueue(label:)` 排掉。

## 修复

- `Sources/SrtFlow/InstantTooltip.swift`：hosting 外面垫一层普通 `NSView` 再挂成
  `contentView`，面板尺寸就只由 `setFrame` 说了算。同时加了一个
  `panelFrameForChecks` 只读口子给自检量落点。
- `Sources/SrtFlow/Resources/{en,zh-Hans}.lproj/Localizable.strings`：补齐 73 条
  提示文案（en 恒等、zh-Hans 译文），删掉 6 条改造后已失效的旧键
  （`Split at playhead (⌘B)` 这类带括号快捷键的写法）。
- 顺着这条线把**全仓库**扫了一遍，另有 108 条界面文案（录屏面板与全部失败原因、
  工程菜单与文档提示、标记与导出）也从没进过表；复审又逼出 13 条藏在动态 key
  后面的（标记颜色、录屏来源、烧录范围说明）。合计 **194 条**。
- 新增 `checks/LocalizationCoverage/`（Swift）+ `scripts/check-localization-coverage.sh`：
  把「写死的文案必须两张表都有」升成**全局**守卫，长期约束写进
  [本地化](../architecture/localization.md)。提示那一类不再单独维护一份规则。

## 验证

- `scripts/check-instant-tooltip-panel.sh`（新增，**不在 `check-all.sh` 里**：它要建
  真实窗口，无图形会话会假红，归 [GUI 冒烟流程](../testing/gui-smoke-testing.md)）：
  拿真实的 `InstantTooltipController.show` 对已知位置的锚点弹提示，量面板真实
  落点，9 条断言全绿。
  **反向验证**：把 hosting 改回直接当 contentView，9 条里红 6 条、退出码 1：
  ```
  FAIL 面板摆好之后不许自己改尺寸/挪位置：摆位 (335, 1493, 192, 25) → 稳定 (335, 1186, 192, 332)
  FAIL 单行提示的面板高度不该超过 60：实际 332
  FAIL 下方放不下时要翻到控件上方：期望 926，实际 619
  ```
- `scripts/check-localization-coverage.sh`（新增，在 `check-all.sh` 里）：511 条界面
  文案在两张表里都有，两张表键集相同、无重复键、无空译文、占位符一致。
  **反向验证（缺文案）**：删掉 zh 表里 `Start Recording` 一行 → `FAIL zh-Hans 表里
  没有："Start Recording" ← Sources/SrtFlow/ScreenRecordingSetupView.swift:114`，
  退出码 1；补回去退出码 0。（第一版守卫用 grep 写，漏掉换行写的调用，已改用
  Swift 扫描。）
  **反向验证（重复键）**：修 `"Size"` 之前，守卫直接报出
  `FAIL en 表里 "Size" 出现了两次` / `FAIL zh-Hans 表里 "Size" 出现了两次`，退出码 1；
  改成 `"Font size"` 之后退出码 0。再把 `"Font size"` 手工写两遍 → 又变红。
  **反向验证（三条兜底）**：只从 zh 表删掉一个静态扫不到的动态 key（`Original SRT`）
  → `FAIL 只有 en 表里有`；把一条译文清空 → `FAIL 译文是空的`；译文少写一个 `%@`
  → `FAIL 占位符对不上`；把 `%d` 换成 `%1$d` → 同样红。四次退出码都是 1。
  **测出来抓不住的一类**：两个同类型占位符对调（`%@ … %@`）—— 调完序列一模一样，
  静态分辨不出，所以规矩改成「要换语序就用 `%1$@`」，并写进架构文档。
  （这一条本来在文档里写成「顺序也要一样、调换会红」，实测才发现是错的。）
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
   **用户报了一处，就该去数还有多少处** —— 这次报回来 1 条，实扫出 194 条。
   同一族的还有「键重复」：翻译过了，但显示的是另一个词，比没翻译更难看出来。
   **一个键只能有一个含义。**
4. 这条 bug 出在「加了守卫的功能」上：`checks/instant-tooltip-wiring.sh` 当时只钉了
   接线（不许用 `.help`、快捷键单一来源），没钉**结果**（提示最终落在哪、写的是哪种
   语言）。**守卫要盯用户看得见的那一面，不能只盯代码写法。**

## 复审补记（同日）

代码复审又挑出三处，都已修：

1. **真实窗口的检查不该进 `check-all.sh`。** 它是本地与 CI 的统一入口，AGENTS.md
   写明真实窗口走 GUI 冒烟；无图形会话的环境跑它只会假红。已移出，并写进
   [GUI 冒烟流程](../testing/gui-smoke-testing.md) 的「已自动化但要图形会话」一节。
   *教训：守卫放错入口，和没有守卫一样会浪费别人的时间 —— 假红比没有更烦人。*
2. **本地化守卫仍有假绿路径。** 只扫调用点的字面量，漏了 `String(localized:)` 和
   动态 key（`L10n(section.title)`）—— 后者把表里对应条目全删掉也照样全绿。已补：
   动态 key 顺着属性名找到计算属性体里的字面量；`String(localized:)` 进扫描清单，
   生产代码里那一处也改回 `L10n`（它只认系统语言，App 内切中文时不跟着变）。
   顺带把这一类查出的 13 条真文案补齐，并加了三条兜底：两张表键集相同、译文非空、
   占位符一致。
   *教训：**守卫自己也要被审**。「加了守卫」不等于「覆盖住了」，得具体问一句
   「哪种写法它看不见」。*
3. **文档与注释漂移**：架构文档写 132 条、案例写 181 条；字符串表的表头注释还指着
   `instant-tooltip-wiring.sh`，甚至引用了一个从不存在的 `checks/localized-strings-coverage.sh`
   （中途改过方案，注释没跟着改）。已统一。
   *教训：数字和路径是会烂的引用，改方案时要顺手全仓库搜一遍旧名字。*
