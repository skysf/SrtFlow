# 时间线捏合缩放：唯一可靠的实现与全部失败方案

> 改 `Sources/SrtFlow/VideoEditTimelineView.swift` 里任何手势/滚动相关代码前必读。
> 这个功能曾经"修好"过多次、真机上反复失败，2026-08-03 硬件实测后定案。

## 结论

触控板捏合缩放时间线**只能用 local event monitor** 实现：

- `NSEvent.addLocalMonitorForEvents(matching: [.magnify, .scrollWheel])`，在事件
  进入窗口分发**之前**处理（SwiftUI / ScrollView 拦不到这一层）。
- 用一个 `hitTest` 恒返回 `nil` 的透明参照 NSView（`TimelineZoomReferenceView`）
  铺满时间线视口，只做几何判定：光标在视口内才缩放并 `return nil` 吞掉事件，
  否则原样放行——点选、拖动、普通滚动零干扰。
- Ctrl + 滚轮是等价的缩放入口（`factor = exp(-scrollingDeltaY * 0.025)`），
  与捏合共用同一个 handler，也是自动化回归时唯一可注入的路径。
- 缩放锚点：记住光标下的时刻与其视口 x，缩放后下一轮 main loop 把该时刻滚回
  同一 x（CapCut 式"指针下缩放"）。

实现：`VideoEditTimelineView.swift` 的 `TimelineMagnificationBridge`。

## 为什么其他方案全部失败（别再回去踩）

两指刚落上触控板时，系统先发 `scrollWheel`（phase = mayBegin）来决定这一轮
手势序列的接收者，并把整个序列**锁定**给命中的视图（时间线的 NSScrollView）。
此后同序列的 `magnify` 事件**不再重新 hitTest**。因此：

| 失败方案 | 失败原因 |
|----------|----------|
| SwiftUI `MagnificationGesture` / `.simultaneousGesture` | 横向 ScrollView 内部收不到捏合 |
| 透明 AppKit 捕获层：`hitTest` 按 `NSApp.currentEvent` 类型选择性命中 + 重写 `magnify(with:)` | 序列已被 mayBegin 锁给 ScrollView，捕获层永远等不到 magnify |
| NSView 重写 `beginGesture`/`magnify` 靠响应链 | 捕获层是 overlay 兄弟节点，不在 ScrollView 的响应链上 |

**最阴险的一点**：这些方案编译全过、用合成调用测 handler 也全通——只有真实
硬件手势会暴露路由问题。所以任何改动都必须真机验证（见下）。

## 回归验证清单

1. `swift build --arch arm64`（Rosetta 终端的架构坑见 `docs/build/build-and-packaging.md`），
   并用 `strings 二进制 | grep <新增字符串>` 确认测试包真含新代码。
2. 注入 Ctrl+滚轮（可用公开 CGEvent API，流程见 `docs/testing/gui-smoke-testing.md`），
   确认刻度/片段/缩放滑块三者同步变化，且到达 4–120 的边界钳制。
3. 真实捏合公开 API 造不出来，最后一步让用户按一次，或起
   `log stream --predicate 'category == "timeline-zoom"'` 实时看
   （`Logger` subsystem 为 `com.srtflow.SrtFlow`；注意 **`log show` 事后查
   ad-hoc 签名的调试拷贝一条都查不到**，只能 stream）。
4. 回归面：普通横向滚动、片段点选/拖动不得受影响（monitor 对非捏合、非
   Ctrl+滚轮一律 `return event` 放行）。
