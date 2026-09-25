# 2026-09-24 点了标记按 ⌫ 删不掉：点一下就弹面板，备注框把 ⌫ 吃了

## 症状

用户：时间线上的标记「删不掉」。点一下块顶上的标记帽子，按 ⌫，标记还在；再点别处让面板
消失，再按 ⌫，还是还在。同一轮用户还拍了板：去掉贯穿块的那道竖线（只留帽子）、单击只选中、
双击才弹面板、右键要有菜单（删除 / 换色 / 备注）。

## 根因

单击帽子做了两件事：选中标记，**并且立刻弹出编辑面板**（`.popover`）。面板里第一个控件
是备注 `TextField`，面板一出现它就成了第一响应者。编辑器的按键监听（`VideoEditView.handleEvent`）
第一条规矩是「第一响应者是 `NSTextView` 就别抢按键」（正在打字时 ⌫ 必须是删字），于是 ⌫
原样放行、进了备注框。两条路都到不了 `deleteSelected`：

1. 面板开着：⌫ 进备注框（框是空的，看起来什么都没发生）。
2. 点别处关掉面板：点的是时间线空白处 = 「点非素材处移播放头 + 清选择」，标记的选择
   一起被清了，再按 ⌫ 什么都不选、自然什么都不删。

进程内冒烟驱动（App 不激活、没有 key 窗口）里第一响应者永远是 nil，所以它复现不了第 1 条 ——
但它能证明面板确实开了（`focus` 步骤看到 `_NSPopoverWindow`）；第 1 条是按代码和 AppKit 的
第一响应者规则推出来的：面板窗口成为 key 时，`NSTextField` 进入编辑，`firstResponder` 是
它的 field editor（`NSTextView`）。

## 修复

`Sources/SrtFlow/VideoEditTimelineMarkers.swift`：

- 竖线去掉，一枚标记只剩帽子（用户拍板）。
- 单击 = 只选中（`onTapGesture`），**不弹面板**；双击 = 选中 + 弹面板（`onTapGesture(count: 2)`
  挂在前面，同文字块）。
- 帽子上挂 `.contextMenu`：删除标记、颜色子菜单（当前色打勾）、「编辑备注…」（打开面板）。
- 新文案 `Colour` / `Edit Note…` 进 en / zh-Hans 两张表。

第一版用 `NSApp.currentEvent?.clickCount` 分流单双击（同字幕 cue 块）。在冒烟驱动里点帽子
**必现段错误**（`SystemSegmentedControl._overrideSizeThatFits` 里 `objc_opt_class` 访问 0x1e），
去掉 `.contextMenu` 照样崩、换回老代码不崩、换成两个 `onTapGesture` 就不崩。驱动是把合成
事件直接交给窗口的，`NSApp.currentEvent` 拿到的不是这一下 —— 具体是哪个对象被释放了没有
追到底，但它只在这条路上崩，两个手势的写法在真机和驱动里都稳。字幕 cue 块还留着
`clickCount` 那套，它在驱动里点过没崩（`func.json`）；再遇到这种崩溃先怀疑它。

## 验证

冒烟驱动（`marker4.json`，工程拷贝在 /private/tmp 下，见下面的教训）：

| 步骤 | 结果 |
| --- | --- |
| 选中一段主轨素材，再单击标记帽子 | 标记选中、素材选择清掉，**没有** popover 窗口 |
| 按 ⌫ | 标记数 1 → 0，素材还在 |
| 再打一枚，双击帽子 | 标记选中，可见窗口里多出 `_NSPopoverWindow` |

守卫（`scripts/check-project-file.sh` 标记那一节）：`onTapGesture(count: 2)` 在、`.contextMenu`
在、单击手势的函数体里不许出现 `editing`。反向验证：把 `editing = marker.id` 放回单击手势 →
「标记单击又弹面板了」红；恢复后绿。

右键菜单驱动不了（菜单是 AppKit 的模态跟踪循环，合成事件进不去），列进
[轨道块标记](../architecture/clip-markers.md) 的人工回归清单。

## 教训 / 防回归

- **弹出带输入框的面板 = 交出键盘。** 任何「点一下就弹出带 TextField 的 popover」都会让
  这一下之后的快捷键失效；要让 ⌫ / 空格这些还管用，面板只能由明确的第二个动作（双击、
  菜单项）打开。长期约束写进 [轨道块标记](../architecture/clip-markers.md) 第十一节。
- **冒烟驱动的工程拷贝必须放在 `~/Downloads`、`~/Desktop`、`~/Documents` 之外。** 调试用的
  `SrtFlowDev.app` 每次重编都是新签名，TCC 每次都重新弹「想访问下载文件夹」；人不点，App
  就卡在第一次 `getxattr` 里（`sample` 看到的是 `bookmarkData` → `getxattr` 一动不动），
  冒烟脚本停在 `settle` 上、120 秒后报「条目=nil」，怎么看都像是工程没打开。而且素材路径不止
  在 `media` 表里 —— 每段还带 `sourceURL`（`file://` 形式），拷贝时都得改。用
  `scripts/gui-smoke/in-process/copy-project.sh` 拷，它把这几处一起改掉。
- **把「驱动里崩」和「产品里崩」分开记。** 这次只在驱动里崩，换个等价写法绕开了；没找到根因就
  写下来，别当成修好了。
