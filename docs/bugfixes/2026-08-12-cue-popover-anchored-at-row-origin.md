# 2026-08-12 双击字幕的就地编辑浮层弹在很偏左的地方

## 症状

时间线上双击一条字幕 cue，就地编辑的浮层不出现在那条 cue 的上下，而是固定弹在
**字幕行的最左端**（用户截图：被点的是靠近播放头、时间线约 00:18 处那条橙色块，
浮层却贴在行首、还压在别的轨道上面）。

时间线缩放得越大、被点的 cue 越靠右，偏得越远：cue 在 00:00 附近时几乎看不出问题，
所以第一轮冒烟（三条 cue、最小缩放、双击第 2 条）没抓到它。

## 根因

**`.offset()` 只改渲染，不改布局框；`popover` 锚的是布局框。**

字幕行是一个 `ZStack(alignment: .topLeading)`，宽度就是整条时间线的
`contentWidth`；每个 cue 块都是同一个原点上的 `RoundedRectangle`，靠
`.offset(x: cue.start * pps, …)` 画到自己的时间位置上（这是时间线全线的画法，
拖动过程也依赖它 —— 见 [timeline-drag-gestures.md](../architecture/timeline-drag-gestures.md)：
拖动中不写 `TimelineState`，块画在哪只由 offset 决定）。

`.popover` 挂在这个块上时，SwiftUI 拿的是块**未偏移**的布局矩形 —— 也就是行的
左上角。于是无论点哪条 cue，浮层都锚在 x = 0。

## 修复

把 popover 从 cue 块上摘下来，**挂到整行上，并用 `attachmentAnchor: .point(…)`
把锚点按比例算到那个块的中心上沿**（`VideoEditTimelineView.swift`：
`subtitleRow(kind:)` 末尾的 `.popover`，以及 `cueAnchor(_:)` / `editingCueValue(in:)`）：

```swift
let width = max(TimelineMarquee.cueMinimumWidth, (cue.end - cue.start) * pps)
let center = cue.start * pps + width / 2
return UnitPoint(x: min(max(center / contentWidth, 0), 1), y: 0)
```

`UnitPoint` 是相对整行宽度的比例，行会随横向滚动一起平移，所以缩放/滚动之后锚点
仍然跟着块走，不需要额外补偿滚动量。

顺带保持的两件事：浮层的显隐判据带上行别（原文 / 译文），否则两条镜像轨会同时弹出
一个；块宽用的仍是与框选命中共用的 `TimelineMarquee.cueMinimumWidth`，短 cue 的锚点
落在**看得见的**那个块中心上，而不是零宽的理论位置。

## 验证

GUI 冒烟（真实窗口 + 合成双击，流程见
[gui-smoke-testing.md](../testing/gui-smoke-testing.md)）：

- 最小缩放（24 pps）双击第 3 条 cue（5.5–7.5s）：浮层箭头落在该块正上方 ✅
- 连点 4 档放大（约 96 pps，行宽远超视口）后双击第 2 条 cue：箭头仍在该块正中 ✅
- 两次都验到输入框自动聚焦、回车提交、右栏与预览叠层同步更新。

`scripts/check-all.sh` 17 项全过。

## 教训 / 防回归

1. **在时间线里给 offset 定位的元素挂任何「弹出物」（popover / tooltip / 菜单），
   都必须自己给锚点。** 时间线上的块全是 offset 画出来的，布局框都在行首；把
   `.popover` 直接挂上去一定弹到左边。要么用 `attachmentAnchor: .point(UnitPoint)`
   自己算，要么改成用 `.position`/padding 布局 —— 但后者会动到拖动手势那一套纪律，
   不要为了一个浮层去改它。
2. **验证「位置对不对」这类问题，样本必须不在原点附近。** 第一轮冒烟点的是靠左的
   cue、最小缩放，偏移量小得看不出来。这条已写进
   [subtitle-track-visibility-and-layout.md](../architecture/subtitle-track-visibility-and-layout.md)
   的人肉回归清单（放大 + 靠右的 cue 各来一次）。
3. 自动化够不着：SwiftUI 的 presentation 落点没有可断言的接口，这一条只能靠人肉
   清单 + 真机截图。
