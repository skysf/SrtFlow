# 2026-08-05 Inspector 数值框横向拖调完全无效：两层根因（附 ±1px 被归一化吞掉）

## 症状

给 Transform 数值框（`InspectorScrubbableNumberField`）加「按住 ~0.175s 再横向
拖动改值」的手势后，用户实测左击长按左右拖动，数值完全不变；松手后字段直接
进入文本编辑态。上下箭头、文本输入正常。

复审又抓到一个独立问题：默认 Position 0 点一次上箭头，值闪一下又回 0
——±1px 步进在 1920 宽画布上完全无效。

## 根因

拖调无效是两层，叠在一起，修掉一层都不够：

1. **`NSTextField.currentEditor()` 不能当「本字段在编辑中」用。**手势入口用
   `guard currentEditor() == nil` 判「未编辑才启动拖调」。实测窗口里**任何一个**
   字段编辑过一次、共享 field editor 被创建之后，`currentEditor()` 对**没在
   编辑**的字段也返回非 nil——入口从此永远走不进去，所有按下都被转发回原生
   文本处理。文档说它「未编辑时返回 nil」，实际行为不是这样。
2. **检查器一出现，AppKit/SwiftUI 的焦点系统会自动把第一响应者塞给某个数值
   框**（用户截图里 Position X 凭空带着焦点圈就是它）。字段被动进入编辑态，
   而设计上编辑态的鼠标交互全数交回原生文本行为，于是「新选中剪辑后第一次
   拖动」也必然失败。这一层让第 1 层修完后现象依旧。

±1px 失效的根因独立：`placementMutation` 的默认布局归一化用固定容差
`0.001`（归一化单位），1920 宽画布上 1px 只有 `1/1920 ≈ 0.00052` ——
+1px 的结果落在容差内，被归一化回 nil（默认），显示回 0。

复审再抓到第三个确定性 bug：**首个满足条件的 drag 事件只武装不结算**。
追踪循环在第一次「已长按且位移 ≥3pt」的 drag 里把 `refX` 设成**该事件的
位置**然后 `continue`——这个事件携带的整段位移被吞掉。事件序列只有
`mouseDown → 长按 → 一次 dragged(+10pt) → mouseUp` 时数值完全不变
（拖太快、事件被系统合并成一两个时就是这种序列）。此前一次自动化拖动
「未生效」被误判为注入工具抖动，实际就是这条代码路径。

另有一处开发期弯路值得记：最初用 `NSEvent.addLocalMonitorForEvents` 旁听
`.leftMouseDragged/.leftMouseUp` 做拖动追踪，事件时序不可靠（拖动不触发、
松手总落进点击分支）；改用 AppKit 标准的 `NSWindow.nextEvent(matching:until:
inMode:dequeue:)` 追踪循环（取事件带短超时，每次醒来查取消条件）后事件
一个不漏。手势判定不要用旁路监听器。

## 修复

`Sources/SrtFlow/InspectorScrubbableNumberField.swift`：

- 「在编辑中」改为精确判定 `isActivelyEditing`：窗口第一响应者是 field
  editor（`NSTextView` 且 `isFieldEditor`）**并且**它的 delegate 就是本字段。
  `updateNSView` 里防覆盖的守卫同步换掉（否则一旦有字段编辑过，SwiftUI 的
  新值再也推不进来）。
- 构造时 `refusesFirstResponder = true` 拒绝一切自动聚焦；只有用户真实点击
  （普通点击分支）才临时放行 `refusesFirstResponder = false; selectText(nil)`
  进入编辑，`controlTextDidEndEditing` 里恢复拒绝。
- mouseDown 里用 `NSWindow.nextEvent` 追踪循环做「按住 0.175s → 横向位移超
  阈值 → 拖调」的判定；参照点重放绝对位移，修饰键切换时从最后一次实际
  应用的量化值重定基准。Escape/App 失焦/视图失效/mouseUp 丢失走取消路径
  （`onScrubCancel` → `cancelLiveEdit`），`defer` 保证收尾恰好一次。
- 首事件吞位移：有效位移起点冻结在**长按期满时刻**（没动=按下位置，动过=
  最后一个等待期位置），首个满足阈值的 drag 以该起点**立即结算**；
  `mouseUp` 时已在拖调则按 up 的最终坐标再结算一次。单事件序列
  `down → 长按 → dragged(+10) → up` 现在精确 +10。
- 修首事件时又实测出一个死代码：App 失焦取消判 `NSApp.isActive` 永远
  不触发——追踪循环只出列鼠标/键盘事件，失焦的 appKitDefined 事件滞留
  队列没被处理，`isActive` 在循环内恒为 true。改用
  `NSWorkspace.frontmostApplication`（系统实况，不依赖本进程事件处理）。

`Sources/SrtFlow/VideoEditProject+Transform.swift`（±1px）：

- `placementMutation` 的归一化容差从固定 `0.001` 改成**半个输出像素**
  （X/宽 `0.5/renderWidth`、Y/高 `0.5/renderHeight`）：±1px 稳稳落在容差
  外，精确回到 0 仍归一化为 nil、Reset 置灰逻辑不变。长期约束落在
  [preview-free-transform](../architecture/preview-free-transform.md)。

## 验证

真实窗口（SrtFlowDev.app + CGEvent HID 注入 + AX 读值）全套过一遍：

- 选中剪辑后 AX 查焦点为 `AXOutline`，不再有字段被自动聚焦；
- 1920 画布：Position 0→+1→0→−1→0 全部生效，回 0 后 Reset 正确置灰；
  4K（3840×2160）画布同样 ±1 生效；
- **单事件序列**（长按后只发一次 dragged + 一次 mouseUp，杜绝中间事件
  掩盖首事件 bug）：+10pt→+10、−10pt→−10、Shift+20pt→+2、Option+4pt→+40
  全部精确；drag(−6)/up(−10) 坐标不同时终值按 up 结算（−10）；+2pt 不触发
  拖调（仍进文本编辑）；等待期先动 +15pt（被消费）期满后再动 +10pt 只计
  +10；
- 多事件拖动 = 一次 Undo 完全恢复、一次 Redo 恢复；箭头单击 = 一次
  Undo；Escape 中途取消恢复原值、不占撤销栈、随后拖动正常；Finder 激活
  （App 失焦）中途取消回滚、随后拖动正常；
- Position/Scale/Rotation/Opacity 四行各自两帧场景：播放头处拖调只替换
  同一帧（另一帧数值不动），整次拖动一步撤销（T1 打帧 → T2 输入新值
  落帧 → T2 拖 +10 替换 → ‹ 回 T1 值不变 → › 回 T2 为拖后值 → 1×Undo
  仅回退拖动）；
- 光标：数字区 resizeLeftRight、箭头区普通箭头、编辑态 I-beam、
  退出编辑恢复 resize；
- 极值 `-960`/`-1920`（去掉千位分隔符后）/`400`/`-359.9`/`100`/`45`
  全部完整渲染；英文与中文最窄 Inspector 无横向溢出、Crop 四项同行；
- 拖动期间传输条无重建转圈；松手后预览画面按新值更新（Opacity 0 → 黑屏）。

`swift build --arch arm64`、`swift run SrtFlowCoreChecks`（184 项）、
`scripts/check-project-file.sh`（72 项）、`git diff --check` 全过。

## 教训 / 防回归

长期约束已落到
[inspector-scrub-number-field](../architecture/inspector-scrub-number-field.md)
（写入路径、取消、焦点、光标、追踪循环）与
[preview-free-transform](../architecture/preview-free-transform.md)
（归一化容差必须亚像素），要点：

- 判「这个 NSTextField 此刻在编辑」永远用「firstResponder 是 field editor
  且 delegate === self」，别信 `currentEditor()`。
- 自绘手势的输入控件放进 SwiftUI 检查器时，必须默认 `refusesFirstResponder`，
  否则焦点系统的自动聚焦会让控件凭空进入编辑态，手势入口整个失效。
- AppKit 里 mouseDown 起手的手势判定用 `NSWindow.nextEvent` 追踪循环
  （带超时轮询取消条件），不用 local event monitor。
- 任何「约等于默认就归一化回 nil」的容差都要用输出像素换算，固定归一化
  常数会随画布尺寸吞掉最小步进。
- 调试期向临时文件写日志时**别在进程活着时 truncate**——FileHandle 的写
  偏移不会回退，文件头会出现一段不可见的 NUL，`cat` 看着像空日志。
