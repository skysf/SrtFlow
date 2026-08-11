# 即时提示（Instant Tooltips）

全 App 的按钮，鼠标一放上去就弹提示，有快捷键的在右边挂一个键帽，移开立刻消失。

本文只写**长期约束**。实现在 `Sources/SrtFlow/InstantTooltip.swift`。

## 一、为什么不用系统的 `.help()`

`NSView.toolTip` 有约 1 秒的首次延迟，延迟由系统私有的 `NSToolTipManager` 管，
**没有公开 API 能调**。产品要求是「立刻」，所以提示只能自己画一层。

由此定下的规矩：**全仓库不许再直接用 `.help(`**，一律走 `.instantHelp(...)`。
`checks/instant-tooltip-wiring.sh` 扫着，留一处就是留一个「这个按钮慢一秒、还
不显示快捷键」的洞 —— 这种洞肉眼扫一遍 UI 根本发现不了。

## 二、快捷键的显示和挂载只有一个来源

`HelpShortcut` 同时管两件事：提示上显示成什么样（`display`），以及要不要顺手把
SwiftUI 的键盘等价符挂上（`key` / `modifiers`）。调用点写一次：

```swift
ToolbarIcon(icon: "scissors", help: "Split at playhead", shortcut: .command("B")) { … }
```

**不许再单独写 `.keyboardShortcut(...)`。** 分成两处写，提示上的 ⌘B 和真正生效
的键迟早对不上，而这种漂移只有用户按下去才发现。守卫扫 `keyboardShortcut(`，
只放过两种：

- `.defaultAction`（对话框默认按钮）：等价符由它提供，键帽用
  `.instantHelp(shortcut: .defaultAction)` **只显示**，重复挂会让同一个键有两个
  响应者。
- `SrtFlowApp.swift` 的菜单命令：菜单自己会画快捷键，也没有 hover 一说。

### 无修饰单键一律 `.plain`（只显示不挂载）

空格、M、A、B、V、⌫ 用 `.plain("M")`：**无修饰的键盘等价符会抢走文本框的
输入** —— 用户在字幕里打一个 "m" 就变成打标记。这些键由
`VideoEditView.handleEvent` 的事件监听接，那边会先让开正在打字的输入框。

## 三、事件走 SwiftUI 的 hover，不走 NSTrackingArea

`.onHover` 是这个 App 里已经跑通的机制（标记帽子的气泡、裁切把手的光标、行高
拖调都靠它）。

试过 AppKit 的 `NSTrackingArea`：装在 SwiftUI 的 `background` 里，量出来的
`visibleRect` 是错的 —— 20×18 的控件报出 1127×363。没有实证支撑的机制不进生产。

## 四、位置由 AppKit 算，提示是独立面板

- **屏幕坐标只有 AppKit 算得准**。SwiftUI 的 `.global` 是窗口坐标，还得自己去掉
  标题栏，换算写错一次就是全 App 的提示都偏。所以 `background` 里垫一层
  `TooltipAnchorLayer` 专门量位置。
- 那一层**绝不能吃点击**（`hitTest` 返回 `nil`）：它和控件同区域，吃了事件按钮
  就按不动了。仓库里 `TimelineZoomReferenceView` 同一个写法。
- 提示是一个 `NSPanel` 而不是 SwiftUI 的 overlay：overlay 会被父视图裁掉、被
  相邻视图盖住，还要一路调 `zIndex`。独立面板没有这些问题。
- 全 App **共用一个**面板。一个控件一个面板的话，扫过工具栏会瞬间造出十几个
  窗口。

## 五、面板自己的三条硬约束（守卫钉着）

1. **`ignoresMouseEvents = true`。** 提示挡住鼠标就会立刻触发下面控件的
   `hover(false)`：提示消失 → 鼠标回到控件 → 又弹出来，肉眼看到的是闪烁。
2. **`animationBehavior = .none`。** 默认的淡入动画会让它慢半拍，而产品要求
   就是「立刻」。
3. **`hide` 必须按 owner 核对归属。** 鼠标从 A 划到 B 时，SwiftUI 先给 B 发
   `hover(true)` 再给 A 发 `hover(false)`；不核对的话 A 的退出会把 B 刚弹出来的
   提示关掉 —— 表现为快速扫过工具栏时提示随机不出现。

摆位规则：默认在控件正下方居中；下方超出屏幕就翻到上方；左右夹进可见区域。

## 六、本地化：两个重载，别混

- `instantHelp(_ text: LocalizedStringKey)` —— 写死的文案，查表翻译。
- `instantHelp(_ text: some StringProtocol)` —— 运行期算出来的字符串（路径、
  素材名、错误文案），走 `Text(verbatim:)`。

系统的 `.help` 也是这么分的两个重载。混用会把用户的文件名当成本地化 key 去
翻译。

## 七、哪些控件不加提示

菜单项（`Menu {}`、`contextMenu {}`）、`confirmationDialog` 与 `.alert` 的按钮
不加：macOS 的菜单不显示 tooltip，菜单自己会在右侧画快捷键。守卫也不扫它们。

## 八、人工回归清单（自动化够不着，发版前实机过）

`.onHover` 对合成鼠标事件不响应（见 [GUI 冒烟流程](../testing/gui-smoke-testing.md)），
所以这一整套**没法用事件注入验证**，只能实机过：

1. 鼠标放到时间线工具栏任一按钮上：提示**立刻**出现（不是等一秒），带快捷键
   键帽；移开立刻消失。
2. 沿着工具栏快速横扫：提示跟着走，不闪烁、不残留、不出现两个。
3. 置灰的按钮（比如空工程时的剪刀）也要有提示 —— 用户最想知道的就是它为什么灰。
4. 提示贴着窗口底边的控件时会翻到上方，不被屏幕边缘切掉。
5. 切换栏目（⌘1/⌘2/⌘3）、关闭面板时，提示不能留在屏幕上。
6. 切到中文界面，提示文案跟着翻译；显示路径/素材名的提示保持原样不被翻译。
7. 提示里写着 ⌘B / ⇧⌘F 的，真按下去要有反应；写着 M / 空格的，在字幕文本框里
   打字**不能**触发对应动作。
