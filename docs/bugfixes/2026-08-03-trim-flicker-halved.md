# 2026-08-03 裁切剪辑块时闪烁卡顿，且裁切量只有鼠标位移的一半

## 症状

在时间线上拖剪辑块两端的把手调长短时，块的边缘一跳一跳地闪烁、不跟手，
"有一种闪烁卡顿的感觉"。注入测试还量出一个之前没人报的隐藏症状：
**拖 10 秒的量只裁掉 5 秒**——裁切速度恰好是鼠标的一半。

## 根因

三个问题叠在一起，主根因是 1：

1. **裁切手势的坐标系随着自己生效的裁切在移动（反馈回路）**。把手是
   `overlay(alignment: .leading/.trailing)` 挂在块边缘的，`DragGesture` 默认
   `.local` 坐标；每应用一点裁切块就变窄，把手的布局位置跟着移动，下一个事件
   算出的 translation 被自己的位移抵消——迭代 `d(n+1) = T - d(n)` 不收敛，
   每 tick 在「已应用 / 被抵消」两个位置间振荡（= 闪烁），时间平均正好一半
   （= 半速）。移动手势没这个病，因为块的**布局**原点固定在行首 0，位置全靠
   `.offset` 渲染偏移，`.local` 坐标系不动。详见
   [timeline-drag-gestures.md](../architecture/timeline-drag-gestures.md)。
2. **磁吸重排动画打在了被裁切的块自己身上**。
   `.animation(.easeOut(0.12), value: clip.timelineStart)` 本意是邻居重排时
   平滑挪动，但裁左边每 tick 都改 timelineStart，位移和宽度全被动画反复
   重定向，把上面的振荡糊成「追手指」的卡顿感。
3. **缩略图/波形每 0.1 秒整条重取**。`.task(id:)` 的 key 含
   `sourceStart/sourceDuration`（0.1s 粒度），裁切中 key 连续变化：每 tick
   异步解码一串帧 + 重读 PCM；旧任务被取消后**结果照样落地**（没查
   `Task.isCancelled`），新旧乱序互相覆盖，内容一闪一闪。

## 修复

全部在 `Sources/SrtFlow/VideoEditTimelineView.swift`：

- 裁切 `DragGesture` 改 `coordinateSpace: .global`，translation 变成纯指针
  位移，反馈回路断掉（根因 1）。
- 新增 `isTrimming` 状态：裁切中该块 `.animation(nil)`，动画只留给邻居；
  顺带在 `hoverScrub` 里挡掉裁切中的悬停扫帧（根因 2）。
- `ThumbnailStripView` / `WaveformView`：已有内容时先 `Task.sleep(200ms)`
  去抖（被新 key 取消就退），落地前查 `Task.isCancelled`；
  `ClipThumbnailCache` 解码循环内也查取消，别让串行 actor 磨废帧堵住新请求
  （根因 3）。

## 验证

按 `docs/testing/gui-smoke-testing.md` 全流程真机验证（SrtFlowDev.app +
`SRTFLOW_SMOKE_VIDEO` 自动导入 30s 测试片 + CGEvent 注入拖动右把手）：

- 修复前：拖 238pt（10s 的量）→ Total length 0:30 → **0:25**（半速实锤）；
  拖动中途截图显示时长几乎没动（振荡的低相位）。
- 修复后：同样的注入 → 0:30 → **0:20.1**，1:1 跟手；中途截图时长连续推进
  （0:22.5），缩略图条被去抖稳稳撑住，无闪烁。
- `swift build --arch arm64` + `SrtFlowCoreChecks` 184 项全过。
- 回归面：块移动手势（.local 没动）、磁吸邻居重排动画仍在、悬停扫帧、
  捏合缩放不经过这些代码。

## 教训 / 防回归

- **挂在会因手势本身而移动的视图上的 DragGesture，坐标系必须用 `.global`**
  （或其他不随内容移动的空间），否则就是反馈回路：症状不一定是明显的抖动，
  可能伪装成「速度不对」这类不易察觉的错。长期约束落在
  [timeline-drag-gestures.md](../architecture/timeline-drag-gestures.md)。
- 连续手势路径上的 `.animation(value:)` 要给正在被拖的元素开豁免，动画只
  留给旁观者。
- `.task(id:)` 的 id 里含连续变化的量时，任务体必须①去抖②落地前查
  `Task.isCancelled`，不然取消只是摆设，旧结果照样乱序覆盖新结果。
