# 2026-08-16 竖版图片块的隐形命中区盖死标尺（点标尺 = 选中图片）

## 症状

L19 工程里，时间线放大到较高倍率后，用户想点标尺移动播放头，结果**每次点击都
变成选中主轨上的图片块 Slide1**，播放头纹丝不动；hover 也被块接管（画面跟着
指针扫帧）。死区精确覆盖 Slide1 横向区间正上方的**整条标尺**，并随内容一起
滚动；同一高度点在左右两侧的录屏/定格块上方一切正常。在死区右键，弹出的是
**剪辑块的右键菜单**（Split at Playhead / Move to PiP / Delete）——实锤标尺
被块占领。

## 根因

`ThumbnailStripView` 的缩略图 tile 用
`Image(...).resizable().scaledToFill().frame(width: tileW, height: 条高).clipped()`
铺满。SwiftUI 的 `.clipped()` / `.clipShape` **只裁绘制，不裁命中区**：
`scaledToFill` 溢出到 frame 之外的部分照样参与 hit test。

- 溢出高度 = (tileW × 图片高宽比 − 条高) / 2，上下各一份；
- tileW = 块宽 / tile 数（tile 数封顶 24），**随缩放线性变宽**；
- Slide1 是竖版手机截图（高宽比 ≈ 2.2），放大后每个 tile 的隐形命中区
  高出块一两百 pt，向上穿过 5pt 行距把 26pt 的标尺整段盖死，向下盖过
  字幕行（字幕行是 VStack 里更靠后的兄弟，命中优先级更高，所以没症状）；
- 块的点选 / 拖动 / `onContinuousHover` 扫帧 / 右键菜单全挂在
  `ClipBlockView` 整棵子树上，命中区域是子视图的**并集**（含溢出），而
  `hoverScrub`、`onTapGesture` 都只用 `location.x`、从不检查 y —— 于是
  「点标尺」以负的本地 y 命中块，表现为选中 + 扫帧，标尺的 seek 手势
  永远收不到事件；
- 横版素材（录屏 16:10）溢出只有 ±10~20pt，穿不过行距，所以只有竖版图
  出事；缩放越大 tile 越宽、溢出越高，与「zoom 到特别大才复现」一致。

## 修复

`Sources/SrtFlow/VideoEditTimelineView.swift`：

- `ThumbnailStripView` 整条 `.allowsHitTesting(false)`（根治：命中区不再
  包含任何溢出）；
- `WaveformView` 同样处理 —— 与缩略图条、关键帧菱形（已有）收成同一条合同：
  **块内装饰不吃事件**，交互统一由 `ClipBlockView` 层的手势 + 底色矩形
  命中面承担，装饰让路零损失。

不改 `.clipped()` 本身：绘制裁剪本来就是对的，错的只是命中。

## 验证

- 修复前，在用户打开的正式包上注入实测（完整证据链）：同一标尺高度，
  Slide1 上方 7 个 x 全部失效、左右邻块上方全部正常 seek；死区随滚动
  跟着 Slide1 走；右键弹出剪辑菜单。
- 修复后 SrtFlowDev 冒烟：导入竖版测试图（540×1170），Ctrl+滚轮放大到
  pps=120、tile 宽 60pt（此几何下修复前溢出 ±48pt，必然盖满整条标尺），
  图片块上方标尺 5 点扫描全部精确落点（0:00.4 / 0:01.6 / 0:02.6 / 0:03.6 /
  0:04.3，逐一等于点击位置）；点块身仍正常选中，悬停扫帧照旧。
  注入期间踩到「Ctrl 修饰键滞留」假死区一枚，坑与解法记在
  [gui-smoke-testing](../testing/gui-smoke-testing.md)。
- 回归守卫：`checks/timeline-drag-wiring.sh` 第 8 节，要求
  `ThumbnailStripView` / `WaveformView` / `keyframeMarkers` 都带
  `allowsHitTesting(false)`。已做反向验证：临时撤掉修复行守卫变红。

## 教训 / 防回归

- **`.clipped()` 是纯视觉裁剪**。任何 `scaledToFill` / 溢出内容，只要不想
  让它吃事件，必须显式 `allowsHitTesting(false)`（装饰）或
  `contentShape`（自身可交互）。长期约束落在
  [timeline-drag-gestures](../architecture/timeline-drag-gestures.md) §1b。
- 命中类 bug 的**无损探针是右键**：在可疑位置右键，看弹出谁的菜单，
  比读代码猜 z 序快得多（已并入 gui-smoke-testing）。
- 手势回调只消费 `location.x` 时，y 方向的越界命中完全隐形 —— 新增
  「横向语义」的手势时想一下：这个视图的命中高度真的等于画出来的高度吗？
