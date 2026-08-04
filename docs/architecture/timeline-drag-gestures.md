# 时间线拖动手势：坐标系与刷新约束

> 改剪辑块的移动/裁切手势、或给时间线加新把手（转场把手、淡入淡出把手等）
> 之前必读。案例背景见
> [2026-08-03-trim-flicker-halved.md](../bugfixes/2026-08-03-trim-flicker-halved.md)。

## 布局模型：块的布局原点永远是 0

`ClipBlockView` 在轨道行里的**布局**位置固定在行首（ZStack topLeading），
横向位置全靠 `.offset(x: timelineStart * pps)` 渲染偏移。这带来一条重要性质：

- 块**本体**上的 `DragGesture`（移动手势）用默认 `.local` 坐标是稳的——
  布局框不随拖动移动。
- 挂在块**边缘**的 overlay 把手（裁切把手；`alignment: .leading/.trailing`）
  的布局位置**随块宽变化而移动**。手势一边报 translation、一边让把手自己
  挪窝，`.local` 坐标下就是反馈回路：`d(n+1) = T - d(n)` 振荡（闪烁），
  时间平均半速（裁切量 = 鼠标位移的一半）。

**规则：凡是手势生效会引起手势视图自身布局移动的，DragGesture 一律
`coordinateSpace: .global`。** 新加把手时先想清楚这条。

## 连续拖动中的刷新约束

1. **动画豁免正在被拖的元素**：`.animation(_, value: timelineStart)` 是给
   磁吸重排的邻居的；被拖/被裁的块自己必须即时跟手（`isTrimming` /
   `dragVisualStart` 判空时给 `nil` 动画），否则 0.12s 动画每 tick 重定向，
   就是「追手指」的卡顿。
2. **异步内容（缩略图/波形）去抖**：`.task(id:)` 的 id 含
   `sourceStart/sourceDuration` 这类拖动中连续变化的量，任务体开头
   `Task.sleep(200ms)` 去抖 + 落地前 `Task.isCancelled` 检查缺一不可——
   取消不拦落地的话，旧结果会乱序盖掉新结果（闪图）。串行 actor 里的
   逐帧解码循环内也要查取消，别磨废帧堵新请求。
3. **预览 seek 防洪**：拖动路径上的 `clock.seek(precise: false)` 走
   `PlayerClock` 的链式 seek（QA1820），调用方不要自己按秒数节流（见
   [2026-08-03-scrub-preview-keyframe-snap.md](../bugfixes/2026-08-03-scrub-preview-keyframe-snap.md)）。

## 回归清单（改这些代码后过一遍）

- 拖右把手 238pt（10s 的量，默认缩放）→ 时长正好少 10s，不是 5s。
- 拖动中块边缘连续跟手，无跳变；缩略图/波形不闪，松手 ~200ms 后刷新。
- 磁吸开着时移动块，邻居仍有平滑重排动画。
- 块移动手势仍 1:1 跟手（它的 .local 依赖布局原点为 0 这条性质）。
