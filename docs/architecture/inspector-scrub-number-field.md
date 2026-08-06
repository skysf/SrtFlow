# Inspector 数值框（InspectorScrubbableNumberField）：写入、取消、焦点与光标合同

> 2026-08-05 引入。改 `InspectorScrubbableNumberField.swift`、
> `VideoEditInspector+Transform.swift`、`VideoEditProject+Transform.swift`
> 之前必读。案例背景见
> [2026-08-05-inspector-scrub-field-gestures](../bugfixes/2026-08-05-inspector-scrub-field-gestures.md)。

## 三条输入路径，两种写入

一个数值框上有三种交互，落到**两条不同的写入路径**，绝不能混：

| 交互 | 路径 | 撤销 |
| --- | --- | --- |
| 文本 Enter/失焦提交 | `value` binding → `setXxx`（`perform`） | 一次提交一步 |
| 上下箭头单击（±1） | 同上 | 一次点击一步 |
| 按住 ~0.175s 后横向拖调 | `onScrubBegin` → `beginLiveEdit`；每 tick `onScrubChanged` → `liveSetXxx`（`liveApply` 从快照重放）；`onScrubEnd` → `endLiveEdit` | 整次拖动一步 |

- **拖调绝不能接到 `value` 上**：每个鼠标事件走一次 `perform` 会把撤销栈拖成
  几十步、AV 合成反复重建。
- Project 侧每个属性一组 `setXxx` + `liveSetXxx` + 私有 `xxxMutation`
  （`VideoEditProject+Transform.swift`）：夹紧、默认归一化、关键帧分支只写
  在 mutation 里一份，discrete/live 永不分叉。
- Position/Scale 的拖调基线取 `project.liveEditOrigin`（手势起点快照），
  不能读拖动中的 `state`——否则上一 tick 的写入会被当成「未改动分量」抄回，
  自己追自己。

## 取消是第一等语义

拖调有**完成**和**取消**两种收尾，组件用 `defer` 保证恰好发一个终结回调、
`isScrubbing` 一定复位：

- 正常 mouseUp → 按 up 最终坐标结算一次 → `onScrubEnd`（一次）→
  `endLiveEdit()` 结一步撤销。
- Escape / App 失焦 / 窗口或视图失效 / mouseUp 丢失（轮询发现左键已松开但
  没收到事件）→ 恢复按下前的显示值 → `onScrubCancel` → `cancelLiveEdit()`
  整体回滚，不进撤销栈。
- 追踪循环取事件带 0.1s 超时，每次醒来查一遍取消条件；**不允许**无限期
  等待且没有取消检测的 `nextEvent`。
- App 失焦判定必须用 `NSWorkspace.frontmostApplication`（系统实况），
  **不能用 `NSApp.isActive`**：追踪循环只出列鼠标/键盘事件，失焦的
  appKitDefined 事件滞留队列没被处理，`isActive` 在循环内恒为 true
  （实测 Finder 激活后手势照常完成）。

## 手势判定的实现约束

- 用 `NSWindow.nextEvent(matching:until:inMode:dequeue:)` 阻塞式追踪循环，
  **不用** `NSEvent.addLocalMonitorForEvents`——旁路监听在文本框场景实测
  时序不可靠（拖动不触发、松手总落回点击分支）。
- 判「本字段在编辑中」用 `isActivelyEditing`（窗口第一响应者是 field editor
  且其 delegate === self），**不能用 `currentEditor()`**——窗口里任何字段
  编辑过一次后它对未编辑字段也返回非 nil。
- 等待期内的位移会被消费掉（不给文本框做拖选），松手按普通点击处理；
  文本拖选只在已处于编辑态时由原生行为提供。
- **有效位移起点定在长按期满那一刻**：等待期没动就是按下位置，动过就是
  最后一个等待期位置。期满后的位移**全部**计入——首个满足阈值的 drag
  事件必须立即按该起点结算（不能只武装后 `continue`，否则单事件拖动
  整段位移被吞、什么都不发生）；`mouseUp` 时已在拖调则按 up 的最终坐标
  再结算一次（事件合并吞掉的最后一段不能丢）。3pt 阈值只是触发条件，
  不是死区。
- 修饰键（Shift 0.1× / Option 10×）切换时从**最后一次实际应用的量化+夹紧值**
  重定基准：不带未量化小数、不带越过上下限的隐藏余量——切换不跳值、
  从边界往回拖立即响应。

## 焦点与光标

- 字段构造时 `refusesFirstResponder = true`：检查器一出现，AppKit/SwiftUI
  的焦点系统会自动把第一响应者塞给某个输入框，字段凭空进入编辑态、拖调
  入口失效。只有普通点击分支临时放行（`refusesFirstResponder = false` +
  `selectText(nil)`），编辑结束恢复拒绝。**自绘手势的输入控件进 SwiftUI
  检查器都要默认拒焦。**
- resizeLeftRight 光标用 `resetCursorRects` 提供：只盖数字框（不盖箭头），
  编辑态走 `super`（文本光标），编辑开始/结束时 `invalidateCursorRects`。
  不用全局 `NSCursor.push/pop`——多个控件交错进出、视图销毁时栈会错位。

## 数值语义

- 默认布局归一化容差是**亚像素**（半个输出像素，X/宽用 `0.5/renderWidth`、
  Y/高用 `0.5/renderHeight`），见
  [preview-free-transform](preview-free-transform.md)——固定 0.001 会把
  ±1px 步进吞回默认值。
- 拖调按字段显示精度量化（整数字段整步进，Rotation 0.1），再夹进值域；
  非有限值不入状态。
