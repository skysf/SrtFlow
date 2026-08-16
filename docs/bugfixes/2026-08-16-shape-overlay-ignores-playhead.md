# 2026-08-16 形状叠层不跟播放头 + 形状块没有裁切把手

## 症状

Add 菜单添加的 Line / Rectangle / Square「无法正常在预览里显示」：

- 添加的那一瞬间形状是出现的（添加会写 `state`，叠层因此重算了一次）。
- 之后播放/点标尺扫帧，形状的**出没完全不跟时间走**：播放头进了形状的
  时间区间它不出现，出了区间它也不消失。停在别处再添加一个形状，旧的
  才突然「对齐」一次 —— 用户感受就是「显示不出来 / 显示得不对」。
- 另外，形状块在时间线上只能整体拖动挪位置，两端没有裁切把手，改时长
  只能去检查器点「Shows for」步进器。

## 根因

`ShapeOverlayCanvas`（VideoEditView.swift）用 `project.clock.displayTime`
过滤可见形状，但它**只 `@ObservedObject` 了 project，没订阅 clock**。
播放头动时只有 `PlayerClock` 发布变化；这个叠层的两个存储属性
（project 引用、boxSize）没变，SwiftUI 判等后直接跳过 body 重算 ——
形状停留在上一次 project 变化时刻的那一帧状态。

同一个文件里的 `ClipTransformCanvas` 早就写着正确做法和注释：
「必须直接订阅时钟：播放头动了，画面上是谁在显示会跟着变。」
形状叠层是后来加的，漏抄了这一条。

裁切把手则是单纯没实现：`ShapeBlockView` 只挂了移动手势。

## 修复

- `VideoEditView.swift` — `ShapeOverlayCanvas` 增加
  `@ObservedObject var clock: PlayerClock`（挂载点传入同一实例），
  `visibleShapes(at:)` 和选中框的 `contains(time:)` 都改读 `clock.displayTime`。
- `VideoEditTimelineView.swift` — `ShapeBlockView` 照抄剪辑块的裁切把手：
  两端 overlay 在 `.offset` **之前**挂上；手势用 `.global` 坐标系
  （`.local` 会随裁切生效跟着块边移动，位移被自己抵消，见
  2026-08-03 裁切闪烁案例）；分割工具下不给把手（`canTrim`），太窄不给。
- `VideoEditProject.swift` — 新增 `liveTrimShape(_:leading:deltaSeconds:)`，
  走 `beginLiveEdit`/`liveApply` 快照重放（幂等），松手
  `endLiveEdit(rebuildsPreview: false)` 收成一步撤销 —— 形状不参与 AV
  合成，不用重建预览。约束：起点端最多回拉到 0；两端收缩下限 0.2s，
  与检查器「Shows for」步进器的下限同一个数。

## 验证

按 `docs/testing/gui-smoke-testing.md` 全流程真窗口验证（SrtFlowDev.app +
SRTFLOW_SMOKE_VIDEO 自动导入 10s 测试视频，CGEvent 注入 + 按窗口 ID 截图）：

- 添加 Rectangle（0–3s）→ 点标尺到 5.7s：形状与变换框**消失**；点回 1.3s：
  重现。修复前同一操作序列截图里形状在 5.7s 仍在画面上（复现件）。
- 拖右把手 +52pt（pps=24）：检查器 Shows for 3.0s → 5.2s，块变长；
  拖左把手 +24pt：起点 0→1s，Shows for 5.2 → 4.2s，右端不动。
- 裁长后点到 5.2s 内：形状按新区间显示（两处修复联动）。
- Line / Square 各加一枚：渲染正常，Square 保形、Line 无框横线；
  不在区间内的形状同帧正确缺席。
- `scripts/check-all.sh` 17 项全绿。

## 教训 / 防回归

- **预览画面上任何按 `displayTime` 取内容的叠层，必须直接订阅
  `PlayerClock`**。只观察 project 的叠层在播放头移动时不会重算 ——
  而且添加/拖动等操作会「顺带」刷新它一次，让 bug 看起来时有时无。
  自查方式：视图 body 里出现 `clock.displayTime` / `project.clock`，
  就检查该视图有没有 `@ObservedObject var clock`。
- 时间线上「块」类视图（剪辑/形状/cue）的交互要保持三处对称；给谁
  加新手势时对照 `ClipBlockView` 的把手合同：`.offset` 之前挂、
  `.global` 坐标、分割工具让路、太窄让路。
