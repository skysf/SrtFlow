# 时间线拖动手势：坐标系与刷新约束

> 改剪辑块的移动/裁切手势、或给时间线加新把手（转场把手、淡入淡出把手等）
> 之前必读。案例背景见
> [2026-08-03-trim-flicker-halved.md](../bugfixes/2026-08-03-trim-flicker-halved.md)
> 与
> [2026-08-09-timeline-clip-drag-lag-and-alignment.md](../bugfixes/2026-08-09-timeline-clip-drag-lag-and-alignment.md)。
>
> 下面第 0、1 节各配了守卫：纯值部分在 `scripts/check-timeline-snap.sh`，
> 自检编不动的 SwiftUI 接线在 `checks/timeline-drag-wiring.sh`。**改这块代码
> 前先看一眼那两个文件在钉什么**，别把守卫绕过去。

## 0. 拖动**过程**中不写 `TimelineState`（最重要的一条）

块在拖动期间画在哪，只由视图状态 `ClipDragSession.offset` 决定；模型只在**松手**
那一下改一次（`VideoEditProject.commitDrag` / `commitShapeDrag` → 纯值的
`TimelineState.applyDrag`，包在**一次** `perform` 里，一步撤销一次预览重建）。

理由不是"省几次重绘"：`state` 是 `@Published`，每一拍写它会连带整个编辑器视图树
（预览区、检查器、所有剪辑块连同缩略图与波形）重建，还要重挂一次自动保存。
单拍处理越久 `mouseDragged` 队列积压越多，**落后量随拖动时间累积**，表现就是
「光标到最右、块还在中间」。

推论：拖动中要让**跟随块**（链接的音频、多选的伙伴）跟着动，靠的也是给它们同一个
渲染偏移，不是去改它们的 `timelineStart`。

## 1. 布局模型与坐标系

`ClipBlockView` 在轨道行里的**布局**位置固定在行首（ZStack topLeading），
横向位置全靠 `.offset(x: timelineStart * pps)` 渲染偏移。

- 挂在块**边缘**的 overlay 把手（裁切把手；`alignment: .leading/.trailing`）
  的布局位置**随块宽变化而移动**。手势一边报 translation、一边让把手自己
  挪窝，`.local` 坐标下就是反馈回路：`d(n+1) = T - d(n)` 振荡（闪烁），
  时间平均半速（裁切量 = 鼠标位移的一半）。→ 用 `.global`。
- 块**本体**的移动手势：块自己会在手指底下挪窝（`.offset`），拖到边缘时
  自动滚动还会把整块内容抽走 —— 两者都会污染以块自身为参照的 translation。
  → 钉在**滚动视口**的命名坐标系 `VideoEditTimelineView.scrollSpace` 上。
  顺带一个好处：`value.location.x` 直接就是指针在视口里的 x，自动滚动判边界
  拿来就用。

**规则：手势视图自己会动（布局或渲染）的，DragGesture 一律显式指定一个不会动的
参照坐标系** —— 有稳定的祖先容器就用命名坐标系，没有才退到 `.global`。

## 2. 连续拖动中的刷新约束

1. **动画豁免正在被拖的元素**：`.animation(_, value: timelineStart)` 是给
   磁吸重排的邻居的；被拖/被裁的块自己必须即时跟手（`isTrimming` /
   `dragOffset` 两个都要判），否则 0.12s 动画每 tick 重定向，画出来的是
   「低通滤波后的鼠标」，手越快落后越多。
   `.animation(_:value:)` 会把该视图**所有**可动画属性一起 animate，不只是
   你盯着的那个 —— 2026-08-09 那次就是只豁免了裁切、漏了移动。
2. **异步内容（缩略图/波形）去抖**：`.task(id:)` 的 id 含
   `sourceStart/sourceDuration` 这类拖动中连续变化的量，任务体开头
   `Task.sleep(200ms)` 去抖 + 落地前 `Task.isCancelled` 检查缺一不可——
   取消不拦落地的话，旧结果会乱序盖掉新结果（闪图）。串行 actor 里的
   逐帧解码循环内也要查取消，别磨废帧堵新请求。
3. **预览 seek 防洪**：拖动路径上的 `clock.seek(precise: false)` 走
   `PlayerClock` 的链式 seek（QA1820），调用方不要自己按秒数节流（见
   [2026-08-03-scrub-preview-keyframe-snap.md](../bugfixes/2026-08-03-scrub-preview-keyframe-snap.md)）。

## 主轨数组顺序 = 时间顺序（不变量）

`mainClips` 的下游全按数组顺序消费：A/B 合成轨的游标式插入（乱序会被
`insertTimeRange` 挤歪 → 黑屏）、转场按数组相邻配对、auto 画布取数组第一段。
磁吸开着由 `packMain()` 维持；磁吸关掉的移动/跨轨落主轨必须在收尾调
`sortMainClipsByStart()`（`TimelineState.applyDrag`、`relocateClip` 已接）。打开工程时
`VideoEditProjectIO.load` 归一治旧文件，`CompositionBuilder.build` /
`ExportGraph.plan` 入口再各防御一次。**新加任何改 `timelineStart` 或往
`mainClips` 里插段的入口，都要么保序要么收尾排一次**；来龙去脉见
[2026-08-08-main-track-array-order-black-frame.md](../bugfixes/2026-08-08-main-track-array-order-black-frame.md)。

## 3. 落点只有一份算法（`ClipDragPlan.resolve`）

一次拖动有两条消费路径：**拖动中渲染**和**松手落地**。它们各自算一遍位置，
就一定会分叉 —— 历史上落地那步偷偷多跑一遍 `clampedStart`，于是拖动中显示
9s、松手弹到 5s。

规则：手势开始时冻结 `ClipDragPlan`（成员、各自轨上**不动的**块、吸附候选、
磁吸模式），之后每一拍只喂 `desiredDelta`，`resolve` 出来的那一份
`DragResolution` **同时**用于渲染和 `TimelineState.applyDrag`。落地那一层
不许再解析任何位置。

配套的三条：

- **整组一个 delta，绝不逐块夹取。** 逐块跑 `clampedStart` 会把同组伙伴当成
  障碍：同轨 A、B 一起选中拖 A，A 会被**旧位置的 B** 顶回原地，整组一动不动。
  碰撞只看不跟着动的块，语义是「**停在接触面**」而不是「弹到障碍另一侧」。
- **跟随块只做水平平移，且和跨轨搬运在同一次 `perform` 里。** 分两次提交
  = 两步撤销 + 视频换轨了而链接音频留在旧时刻（A/V 错位）。
- **磁吸模式下跟随块按被拖块的实际最终落点平移**，哪怕落点被别的块占着也不
  挤开 —— 声画同步优先于顺手避免重叠。

`clampedStart` 现在只剩一个合法用途：**跨轨落地到岸后的让位**（目标轨上的
障碍在手势开始时还不知道，那时候还不知道会落到哪条轨）。同轨移动碰它就是 bug。

## 4. 吸附与对齐线（`TimelineSnap`，纯值函数）

- **两条边都参与吸附**：块的起点和终点各自去够每个候选，所有配对里取位移最小的
  那一种。只比起点的话「右边缘贴上别人的左边缘」永远没反应。
- **候选在手势开始时算一次就冻住**（`ClipDragSession.candidates`）。拖动中重算会
  把**跟着一起动的伙伴**（链接音频、多选的其他块）算成候选 —— 它们上一拍刚被挪到
  手指底下，这一拍就把块吸回上一帧的位置，手感是「拖不动」，而且鼠标越慢越粘。
- **「谁在动」只有一份名单**：`VideoEditProject.movingClipIDs(draggedID:)`，
  候选、渲染偏移、落地三处共用。三处各算一份迟早分叉。
- **落点先夹再算线**：参考线按夹完（`minimumStart`）的位置算，否则线在一处、
  块在另一处。
- **主轨磁吸开着时不给对齐线**：落点由插空决定、松手一律被 `packMain` 覆盖，
  亮线是骗人的。那种情况下改画青色插入指示线，位置由
  `TimelineSnap.mainInsertion` 给 —— **落地必须调同一个函数**，否则指示线会说谎。
- **插入时刻必须在「插入之后的最终数组」上算。** 插进来的块会改变相邻关系，
  转场能叠掉的量按两边任一段的 45% 收紧、跟着就变：A(10s，其后 2s 转场) + B(10s)
  之间插一段 1s 的 M，按插入**前**的数组算是 8s，实际 A→M 只能叠 0.45s，
  M 落在 9.55s。共享 `transitionOverlap` 还不够 —— 指示线和 `packMain` 要共用
  完整的布局函数 `TimelineState.packedStarts`。
- **磁吸模式下插空判定用未夹的中心**：块顶到时间线左端后位置就不动了，中心恰好
  压在第一段的中点上，`center < mid` 永远为假 —— 用户往左拖到底也插不到最前面。

## 5. 视口与缩放

- **弹性尾部只给自由落点的轨道**（画中画/音频/磁吸关掉的主轨/形状）：拖到右缘
  时内容宽度按投影落点临时长出去，松手由新的 `project.duration` 接管。磁吸主轨
  不给 —— 它只能插进现有故事线的某条缝，扩太远只会把插入指示线滚出视野。
- **缩放只有 `VideoEditProject.setPixelsPerSecond` 一个入口**，夹进
  `zoomRange`（4…120）。`pps` 掉到 1 以下时位移换算会被 `max(pps, 1)` 兜底，
  1:1 跟手当场坏掉（鼠标走 100 点、块只走 50 点）。捏合、工具栏按钮、滑块共用它。
- **自动滚动的心跳要有多条退路**：正常松手 `stop()`、视图消失 `onDisappear`、
  视图树被拆 `dismantleNSView`、对象被回收 `deinit`，外加 tick 里自查滚动视图
  还在不在。少一条就可能在 RunLoop 上留一个 60Hz 的空转 timer。

## 回归清单（改这些代码后过一遍）

- 拖右把手 238pt（10s 的量，默认缩放）→ 时长正好少 10s，不是 5s。
- 拖动中块边缘连续跟手，无跳变；缩略图/波形不闪，松手 ~200ms 后刷新。
- 磁吸开着时移动块，**邻居不动**（松手才归位），青色插入指示线跟着中心走；
  松手后块落在指示线那条缝上。
- 块移动手势 1:1 跟手：快速甩一趟，块中心始终在光标下（注入验证做法见
  gui-smoke-testing.md，误差应在 1 像素级）。
- 画中画轨的块左右拖，边缘对上主轨块的边缘时出现通高黄线，且块**吸在线上**；
  起点对起点、终点对终点、起点对终点四种配对都要试。
- 拖到视口左右缘停住：时间线自动横向滚动，块继续跟着光标（内容要够长，
  先放大到内容宽于视口）。
- 磁吸关掉把块拖成乱序再回放：预览各时刻画面都在（守卫在
  check-preview-composition / check-project-file 里）。
- 多选两块一起拖：松手后**两块都在新位置**（别被组内伙伴顶回原地），
  相对错位不变，⌘Z 一次全退回。
- 视频 + 链接音频一起换轨：音频跟到同一时刻（拖完点播放听一句，别只看轨道）。
- 形状块拖动：亮线、吸附、松手不跳，与剪辑手感一致。
- 把块拖到工程末尾之外：自由落点的轨允许（内容跟着长），磁吸主轨不允许。
