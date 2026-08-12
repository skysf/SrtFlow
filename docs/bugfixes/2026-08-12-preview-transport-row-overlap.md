# 压缩预览区时，播放条压到时间线工具栏上

> 2026-08-12。用户报的现象：拖动预览区和时间线之间的分割线（或把窗口调小）
> 时，播放/时长/分辨率/帧率那一行会和下面那排工具按钮（Add、工具、撤销……）
> 重叠在一起。

## 现象

`VideoEditView.previewPane` 的最后一行（`transport`）在压缩过程中越过分割线，
盖到 `timelinePane.toolbar` 那一排图标上。截图里两行叠在一起，图标被文字压住。

## 成因：VStack 里**唯一不肯让步的那个**决定了谁被挤出去

预览区是这么排的：

```
VStack { [缺失素材条] · videoBox · Divider · transport }
```

- `videoBox` 原本钉了 `.frame(minHeight: 220)`，外面还有 `.padding(10)` ——
  **实际最小 240**。
- `transport` 没有任何尺寸约束，是这条 VStack 里最"软"的一个。
- 上半区在 `VSplitView` 里只有 `minHeight: 300`。

240 + 分割线 + 播放条（一行约 34、notice 撑到两行约 46）在**干净状态下**刚好塞
得进 300。但只要再叠一条缺失素材条（约 30），或者 notice 变成两行，这条 VStack
的最小高度就超过了分给它的高度。

关键在于 SwiftUI 遇到"塞不下"时的行为：它**不会**把声明了 `minHeight` 的
`videoBox` 压下去，只会把没有底线的那个挤出容器边界。被挤出去的正是排在最后的
`transport`，它于是画到了下一个 pane 的地盘上 —— 也就是时间线工具栏那一排按钮。

> 一般规律：**VStack 里只要有一个成员拒绝再矮，空间不足时被牺牲的一定是没有
> 底线的那个**，而且是"越界"而不是"被压扁"。谁该让步，必须显式说出来。

## 修法（`Sources/SrtFlow/VideoEditView.swift`）

两边一起改，缺一个都不彻底：

1. **让该让步的真的能让步**：`videoBox` 的下限 220 → 120。预览框是这里唯一
   该缩的东西（它本来就是等比 fit 的黑框，小一点没有任何信息损失）。改完这条
   VStack 的最小高度约 175，离 300 有充足余量。
2. **让不该让步的拿走优先权**：`transport` 加
   `.fixedSize(horizontal: false, vertical: true)` + `.layoutPriority(1)`。
   前者让它按自然高度拒绝被压扁（notice 撑到两行时也如实变高），后者让 VStack
   先满足它、剩下的才归预览框。

只改第 1 条：极端压缩时播放条还是可能被压扁。
只改第 2 条：`videoBox` 仍然拒绝低于 240，越界照旧发生。

## 验证（真实窗口）

按 [GUI 冒烟流程](../testing/gui-smoke-testing.md) 组 `SrtFlowDev.app`，注入拖动
把分割线往上拖到底：播放条与工具栏两行始终清晰分开，无重叠。检查器那一侧
Export 按钮在极限压缩时被切掉是**正常**的 —— `VideoEditInspectorView` 本身就是
一个 `ScrollView`，滚一下就出来。

## 同类风险点

改预览区/时间线的行结构时，先问一句「空间不够时谁让步」：

- 任何挂了 `minHeight` 的成员，都在无声地把压力转移给它的兄弟。
- 工具栏、播放条这类**行高固定的控件条**应当 `fixedSize(vertical:)` +
  `layoutPriority`，而不是靠"反正塞得下"。
- 上半区 `VSplitView` 的 `minHeight: 300` 不是保险丝：它管的是分给 pane 的高度，
  不管 pane 里的内容要多高。
