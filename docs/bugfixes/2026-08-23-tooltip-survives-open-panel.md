# 2026-08-23 点「打开工程」后提示一直悬浮在文件对话框上面

## 症状

鼠标放在「打开工程」按钮上（提示「Open an existing .srtflowproj file ⌘O」正常
弹出），点下去弹出打开文件对话框 —— 提示**不消失**，一直悬浮在对话框上面；
对话框关掉之后它还在，要等鼠标重新划入再划出那个按钮才收起。用户报图可复现。

## 根因

即时提示的收起只有一条路：控件的 `.onHover` 发 `hover(false)` →
`InstantTooltipController.hide(owner:)`。这条路有两个够不着的场景：

1. **模态会话吞掉了 hover 退出。** 点按钮弹 `NSOpenPanel` 后进模态（或
   面板服务接管事件），主窗口的 tracking 更新不再派发，`hover(false)` 既不会
   立刻发生，错过的退出事件在对话框关掉后也不补发 —— 除非鼠标重新进出那个
   控件，提示就永远挂着。
2. **⌘O 触发时连点击都没有。** 鼠标停在按钮上按快捷键打开对话框，同样没有
   任何 hover 变化。

提示面板本身 `level = .popUpMenu`、`ignoresMouseEvents = true`，所以它浮在
对话框之上、也不响应任何点击 —— 挂着就是纯挂着。`hidesOnDeactivate` 帮不上：
打开文件对话框仍属于本 App，应用没有 deactivate。

## 修复

`Sources/SrtFlow/InstantTooltip.swift`：面板可见期间挂两条「全局打断」，任何
一条触发都收起提示（系统 tooltip 同款语义），收起时拆掉，平时不拦事件：

- `NSEvent.addLocalMonitorForEvents`（leftMouseDown / rightMouseDown /
  otherMouseDown / keyDown / scrollWheel）：点按钮那一下、按 ⌘O 那一下就收，
  事件原样放行；
- `NSWindow.didResignKeyNotification`：对话框成为 key、切窗口时收 ——
  菜单栏触发的对话框走不到本地事件监听，靠这条兜住。

所有隐藏路径统一收敛到私有 `dismiss()`（含监听拆除），不许再直接 `orderOut`
—— 监听漏拆就成了常驻的全局事件拦截。

## 验证

- `scripts/check-instant-tooltip-panel.sh` 新增第 4 组用例（需要图形会话，
  故意不在 check-all 里）：4a 发 `didResignKeyNotification` 后面板必须不可见；
  4b 用 `NSApp.sendEvent` 送合成 leftMouseDown（本地监听挂在应用派发这条路上，
  这就是生产路径）后必须不可见；4c 打断之后再 `show` 必须照常弹出。
- **反向验证**：临时注释 `installDismissTriggers()`，4a/4b 两条如期变红
  （2 of 14 FAILED），恢复后 14 条全绿。
- 实机：点「打开工程」弹对话框，提示立刻消失；⌘O 同样；对话框关掉后 hover
  各按钮提示照常工作。

## 教训 / 防回归

- 「移开就消失」这类靠 hover 退出维护的 UI 状态，必须假设**退出事件可能永远
  不来**（模态会话、窗口切换、键盘触发）；打断信号（mouseDown / keyDown /
  resignKey）才是兜底。系统 tooltip 的行为就是这个合同。
- 长期约束已并入 [即时提示](../architecture/instant-tooltips.md) 第五节
  （面板硬约束第 5 条）与人工回归清单第 5 条。
