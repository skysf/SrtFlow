# 2026-08-03 时间线触控板捏合缩放无效（反复"修好"又失败）

## 症状

在 Edit Video 的时间线区域用 MacBook 触控板两指捏合，缩放毫无反应，只能点
工具栏右上角的 +/- 放大镜。此前已"修复"过多次（SwiftUI 手势、局部 monitor、
透明 AppKit 捕获层），每次编译与合成测试都通过，真机捏合依然无效。

## 根因

两个问题叠加，导致"假修复"循环：

1. **事件路由**：两指刚落上触控板时，系统先发 `scrollWheel`(phase=mayBegin)
   决定整轮手势序列的接收者并**锁定**给时间线的 NSScrollView，之后的 `magnify`
   事件不再重新 hitTest。因此一切靠视图命中/响应链的方案（SwiftUI
   `MagnificationGesture`、透明捕获层 + `magnify(with:)`）在真实硬件上必然
   收不到事件——而合成调用 handler 的"测试"绕过了路由，全部误报通过。
2. **构建架构陷阱**：终端跑在 Rosetta 下，裸 `swift build` 编成 x86_64，
   `.build/arm64-apple-macosx/debug/` 里是旧二进制。至少一轮"修复"实际测试的
   是没改过的旧代码（编译警告的行号都对得上新代码，产物却是旧的，极具迷惑性）。

## 修复

`Sources/SrtFlow/VideoEditTimelineView.swift` 的 `TimelineMagnificationBridge`：
改用 `NSEvent.addLocalMonitorForEvents(matching: [.magnify, .scrollWheel])` 在
事件进窗口分发**之前**处理；透明参照视图 `hitTest` 恒返回 `nil`，只做"光标是否
在时间线视口内"的几何判定。视口内的捏合与 Ctrl+滚轮缩放并吞掉事件，其余一律
放行。长期约束详见 `docs/architecture/timeline-pinch-zoom.md`。

## 验证

- 用户真机捏合确认生效（最终判据）。
- 注入 Ctrl+滚轮（与捏合同 handler）：缩放从默认拉到 120 上限，刻度/片段/
  滑块三者同步。
- `strings` 验证测试包含新代码、`lipo -archs` 确认 arm64。
- 核心自检 `swift run --arch arm64 SrtFlowCoreChecks` 全过。

## 教训 / 防回归

- **合成测试通过 ≠ 修复**：凡涉及系统事件路由，必须真实硬件或真实注入验证。
- **每次都要验明测试产物**：`--arch arm64` + `strings` 查新增字符串，见
  `docs/build/build-and-packaging.md`。
- 注入事件前查目标点的窗口叠放（终端常盖在上面），见
  `docs/testing/gui-smoke-testing.md`。
- 改时间线手势/滚动代码前先读 `docs/architecture/timeline-pinch-zoom.md`。
