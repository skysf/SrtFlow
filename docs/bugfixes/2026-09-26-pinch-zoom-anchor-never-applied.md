# 2026-09-26 捏合放大时鼠标底下的内容跑掉：锚点那一步从来没生效

## 症状

用户：「目前我用 Mac 的 trackpad zoom 的时候，我不希望我停留的轨道区域移动……zoom in 放大是往两边
延伸，这个延伸的点就是鼠标停留的点。」

捏合缩放时，内容以时间线视口的**左边**为基准伸缩（滚动量原封不动），鼠标底下那一刻被推到一边；
滚动过之后连左边缘那一刻也在漂 —— 放大一下，刚才看着的那段就不在眼前了。

## 根因

「指针下缩放」2026-08-03 就写了：捏合起手时记下指针底下那一刻和它在视口里的 x，改完比例把那一刻
滚回同一个 x。滚之前要找到时间线的 `NSScrollView`，找法是：

```swift
let pointInRoot = rootView.convert(pointInWindow, from: nil)   // 根视图自己的坐标
guard let scrollView = enclosingScrollView(at: pointInRoot, in: rootView) …
// 里面：rootView.hitTest(point)，再顺着 superview 往上找 NSScrollView
```

`NSView.hitTest(_:)` 要的是**父视图坐标系**里的点，这里传的是根视图**自己**坐标系里的点。SwiftUI 窗口
的根视图（`AppKitWindowHostingView`）是**翻转**的（y 朝下），它的父视图（窗口的 frame view）不翻转 ——
`hitTest` 在里面再换一次坐标，等于把这个点**上下镜像**：指针在窗口下半截的时间线上，它去命中的是上半截
对称的那一处（预览区那一栏），那一路往上没有滚动视图，于是 `timelineScrollView = nil`，锚点那一步直接
跳过。缩放只改了比例、没滚，就是症状里的样子。

2026-09-26 进程内冒烟实测（南极工程的拷贝，1180×860 窗口，指针在主轨上）：

| 找法 | 命中 | 找到的滚动视图 |
| --- | --- | --- |
| 老办法（根视图坐标喂给根视图的 `hitTest`） | `NSHostingView<… NavigationPane …>`（预览那一栏） | 没有 |
| 按父视图坐标 `hitTest` | 时间线的 `DocumentView` | 就是时间线的那一个 |

只有指针恰好落在窗口正中那条水平线附近（镜像之后还在时间线里）时才可能生效，窗口大小、分栏一变就
不对。2026-08-03 那时的布局下有没有碰巧生效过，已经查不清；现在的布局下从来没生效过。

**为什么一直没发现**：

- 2026-08-03 修捏合那一轮的验收是「真捏合事件进不进 App、比例变不变」（公开 API 造不出捏合，那是
  最难的一关），锚点那一步没有任何数字上的检查；
- 「找不到滚动视图就什么都不做」是**静默**的 —— 没有报错，缩放照样能用，只是不锚；
- 架构文档把这条路写成了「事件监视器里拿不到视图树，只能按坐标 hitTest 现找滚动视图，暂时豁免」。
  其实拿得到：捏合的桥本身就挂在时间线的视图树里，时间线手上一直有一份现成的滚动视图
  （`TimelineScrollGeometry`，§5b 的「滚动量的唯一真相」）。豁免就是这个 bug 的藏身处。

## 修复

- 捏合不再自己找滚动视图：`TimelineMagnificationBridge` 从时间线拿它自己的 `TimelineScrollGeometry`
  （`TimelineScrollViewAccessor` 在滚动内容里用 `enclosingScrollView` 认出来的那一个）。指针底下是哪一刻
  由 `TimelineScrollGeometry.location(ofWindowPoint:in:)` 换算：窗口点 → clip view 坐标 → 视口 / 内容坐标。
- 缩放统一走 `TimelineZoom`（`VideoEditTimelineZoom.swift`）；锚点的算术是纯值 `TimelineZoomAnchor`；
  推滚动只由几何入口 `keepAnchored` 做：**同一拍先挪一次，下一轮 main loop 再挪一次**（同一个绝对位置，
  幂等）。只在下一轮挪的话，排版和补挪之间会有一帧画在「左边缘为锚」的位置上（一抖）；只在这一拍挪的话，
  放大时目标会被还没长宽的旧内容尺寸夹住。
- `checks/timeline-drag-wiring.sh` 第 9d 条删掉了给捏合的豁免：滚动位置只许 `TimelineScrollGeometry` 读 / 推。
- 同一次顺手改的（用户同意）：工具栏的放大 / 缩小、⌘= / ⌘-、缩放滑杆以前也不管滚动，一按画面就跳 ——
  现在钉住播放头（不在视口里就钉视口正中）。纵向缩放是新功能，见
  [方案](../plans/2026-09-26-timeline-clipboard-and-zoom.md)。

## 验证

- **进程内冒烟**（南极工程的拷贝；冒烟加了 `zoom` 步骤，和捏合处理器是同样的调用：起手定锚点、逐拍缩放）：
  - 指针在主轨 20.292 秒处放大 3 倍（12 拍）：前后指针底下都是 **20.292 秒**，滚动量 0 → 974；截图上那一刻
    没挪窝。
  - 在靠近开头处缩小到 0.4 倍：滚动量被夹到 0，指针底下从 23.069 秒变成 23.854 秒 —— 左边没有更早的时间，
    只能贴左（预期的例外，已告诉用户）。
  - 纵向 ×2 再 ×0.5（指针在译文字幕行上）：指针底下一直是同一行的同一处，纵向滚动量 0 → 108.9 → 0.3。
  - 同一轮里按老办法 hitTest：命中预览那一栏、找不到时间线的滚动视图（上面那张表）。
- `scripts/check-timeline-zoom.sh`：锚点的算术 70 条（横向任意比例下指针底下同一刻、工具栏的播放头 / 视口正中、
  纵向行内按比例 / 缝里按距离 / 同一份排布原样还原）。
- `checks/timeline-drag-wiring.sh` 的缩放一节（`checks/timeline-drag-wiring/zoom.sh`），**反向验证**：把
  `VideoEditTimelinePinchZoom.swift` 换回修之前的版本，守卫红 6 条（按坐标 hitTest 找滚动视图、自己认
  `enclosingScrollView`、自己赋 `pixelsPerSecond`、自己推滚动、没有 ⌥ 纵向……），换回来转绿。
- 真捏合公开 API 造不出来：发版前按 [捏合缩放](../architecture/timeline-pinch-zoom.md) 的人工回归清单在触控板上捏一遍。

## 教训 / 防回归

- **`hitTest(_:)` 吃的是父视图坐标。** SwiftUI 的宿主视图是翻转的，传错坐标系的结果不是「偏一点」，
  是上下镜像；再加上「找不到就什么都不做」，这个错完全静默。
- **视图树里已经有一份「唯一真相」时，别再用坐标去找第二份。** 时间线的滚动视图只有 `TimelineScrollGeometry`
  一份（[拖动手势 §5b](../architecture/timeline-drag-gestures.md)），给谁开「暂时豁免」，谁就是下一个藏 bug 的地方。
- **「看起来差不多」的行为要有数字。** 锚点对不对，量「指针底下是第几秒」就知道；以前的验收只看比例变没变。
  冒烟的 `zoom` 步骤就是为这个加的（[GUI 冒烟流程](../testing/gui-smoke-testing.md)「四之六」）。
- 长期约束写在 [捏合缩放](../architecture/timeline-pinch-zoom.md)（锚点、纵向缩放、工具栏的锚点）。
