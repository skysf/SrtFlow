# 时间线缩放：捏合、锚点、纵向缩放

> 改 `VideoEditTimelinePinchZoom.swift`（捏合 / 滚轮的事件入口）、`VideoEditTimelineZoom.swift`（缩放的
> 唯一入口）、`VideoEditTimelineZoomAnchor.swift`（锚点的算术）或时间线里任何手势 / 滚动相关代码前必读。
> 捏合这个功能曾经「修好」过多次、真机上反复失败，2026-08-03 硬件实测后定案；锚点那一步
> 2026-09-26 才发现从来没生效过（[案例](../bugfixes/2026-09-26-pinch-zoom-anchor-never-applied.md)）。

## 一、事件怎么进来：只能用 local event monitor

触控板捏合缩放时间线**只能用 local event monitor** 实现：

- `NSEvent.addLocalMonitorForEvents(matching: [.magnify, .scrollWheel, …])`，在事件
  进入窗口分发**之前**处理（SwiftUI / ScrollView 拦不到这一层）。
- 用一个 `hitTest` 恒返回 `nil` 的透明参照 NSView（`TimelineZoomReferenceView`）
  铺满时间线视口，只做几何判定：光标在视口内才缩放并 `return nil` 吞掉事件，
  否则原样放行——点选、拖动、普通滚动零干扰。
- Ctrl + 滚轮是等价的缩放入口（`factor = exp(-scrollingDeltaY * 0.025)`），
  与捏合共用同一个 handler。
- 同一个监视器顺手记下**右键（或 ⌃ 点）按在时间线的哪儿**（`TimelineContextClick`），事件原样放行：
  右键菜单里的「粘贴」落在按下去的那一处（[复制粘贴](timeline-clipboard.md)）。

实现：`VideoEditTimelinePinchZoom.swift` 的 `TimelineMagnificationBridge`。

### 为什么其他方案全部失败（别再回去踩）

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

## 二、锚点：指针底下那一刻不动（2026-09-26 用户拍板：「往两边延伸，延伸的点就是鼠标停留的点」）

- **一轮捏合起手时定死锚点**：指针底下是第几秒（`time`）、它在视口的哪个 x（`viewportX`）；每一拍改完比例，
  把滚动量挪到 `time × 新比例 − viewportX`（`TimelineZoomAnchor.offsetX`）。指针在捏合中不动，定死也不会漂；
  `began` 永远开新的一轮（上一轮的 `ended` 万一没来，不拿旧锚点接着缩）。Ctrl + 滚轮每一下按此刻的指针取锚点。
- **滚动视图只从时间线自己的 `TimelineScrollGeometry` 拿**（[拖动手势 §5b](timeline-drag-gestures.md)），
  指针换算走 `TimelineScrollGeometry.location(ofWindowPoint:in:)`。**别按坐标 hitTest 去找滚动视图**：
  `hitTest(_:)` 吃的是父视图坐标，SwiftUI 的根视图是翻转的，传错了就是上下镜像 —— 2026-09-26 之前就是
  这样，锚点那一步从来没生效（[案例](../bugfixes/2026-09-26-pinch-zoom-anchor-never-applied.md)）。
- **推滚动只由 `TimelineScrollGeometry.keepAnchored` 做**：同一拍先挪一次，下一轮 main loop 再挪一次（同一个
  绝对位置，幂等）。只在下一轮挪 = 排版和补挪之间有一帧画在「左边缘为锚」的位置上；只在这一拍挪 = 放大时
  目标被还没长宽的旧内容尺寸夹住。连续缩放时只有最新那一拍的补挪生效。
- **做不到的例外**：贴着 0 秒缩小、或者缩到整个工程都装进视口时，左边没有更早的时间可露，滚动量被夹到 0，
  内容贴左（用户知道）。

### 工具栏的放大 / 缩小、⌘= / ⌘-、缩放滑杆：钉住播放头

以前它们只改比例、不管滚动，一按画面就跳（2026-09-26 用户同意一起改）。现在走同一个入口
（`TimelineZoom.horizontal(…, keeping: .playheadOrCenter)`）：**播放头在视口里就钉住播放头**（含两条边），
不在就钉住视口正中那一刻（`TimelineZoomAnchor.toolbarAnchor`）。不看鼠标：点按钮、拖滑杆时鼠标在工具栏上；
按 ⌘= 时鼠标可能碰巧停在时间线上，但用户看的是播放头（FCP / Premiere 的键盘缩放同一个口径）。

## 三、纵向缩放：所有视频轨和音频轨一起变高 / 变矮（2026-09-26 用户拍板）

| 入口 | 做什么 |
| --- | --- |
| 按住 ⌥ 捏合 | 纵向缩放。**起手时定轴**：捏到一半松开 ⌥ 不会突然改成横向 |
| ⌥ + Ctrl + 滚轮 | 同上（没有触控板时） |
| ⌘↓ / ⌘↑ | 纵向放大 / 缩小一档（×1.25），方向同 Logic（⌘↓ 放大、⌘↑ 缩小）。接在 `VideoEditView.handleEvent`，输入框里让路 |

- **视频轨和音频轨统一成一个高度**（用户选的 5B：「纵向缩放时所有轨变成一样高，单独调过的作废」）：
  `TimelineRowHeights.setUniform` 记下统一高度、清掉每条轨单独拖过的高度；之后仍然可以单独拖某一条的下边缘
  （它又有了自己的高度）。新开的轨跟统一高度走。起点是**锚点那一行现在的高度**（锚点不在视频 / 音频轨上就从
  主轨的高度起算），乘上这一拍的倍数。区间 28…200（视频轨和音频轨可调区间的交集 —— 「一样高」得两类都够得着）。
- **字幕、文字、形状、滤镜那几条细行不变**（用户选的 4A）：它们的行高和块高是写死的一对，框选的命中判据
  直接靠那个差（[视频轨对等化](video-tracks.md)「行高」）。
- **锚点**：指针指着的那一处不动 —— 按**行**认，不按 y 认（`TimelineZoomAnchor.RowPoint`）：在某一行里 = 行内的
  第几成（行高变了按比例跟着走），在行与行之间的缝或最后一行下面 = 上面那一行下沿往下多远（缝不缩放）。
  ⌘↓ / ⌘↑ 时鼠标在时间线上就钉鼠标那一处，不在就钉视口正中。只推纵向滚动量（§5b：没在推的轴一个字都不许碰）。
- **存进工程、不进撤销栈**：统一高度是 `rowHeights` 里的一个键（`uniform`），和每条轨的行高一样是装饰状态 ——
  不进撤销栈、不重建预览、只标脏（`VideoEditProject.updateRowHeights`，拖轨道头和纵向缩放共用这一个写入口）。
  旧版读到这个键会忽略，丢的只是高度，所以不开新的 formatVersion（[工程文件](video-edit-project-file.md)「行高」）。
- 行怎么排只有一份：`TimelineRowList.rows(for:)`（时间线画它、纵向缩放找锚点、⌘V 找指针底下那一行都用它）。

## 四、回归验证清单

1. `swift build --arch arm64`（Rosetta 终端的架构坑见 `docs/build/build-and-packaging.md`），
   并用 `strings 二进制 | grep <新增字符串>` 确认测试包真含新代码。
2. `scripts/check-timeline-zoom.sh`（锚点的算术）、`checks/timeline-drag-wiring.sh` 的缩放一节（接线：
   不许 hitTest 找滚动视图、唯一缩放入口、工具栏三处钉播放头、⌥ / ⌘↓⌘↑ 纵向、行高写入口不进撤销栈）。
3. 进程内冒烟的 `zoom` 步骤（[GUI 冒烟流程](../testing/gui-smoke-testing.md)「四之六」）：和捏合处理器同样的
   调用，前后各记一次指针底下是第几秒、哪一行的第几成。**锚点对不对看数字**，别只看比例变没变。
4. 真实捏合公开 API 造不出来，最后一步让用户按一次，或起
   `log stream --predicate 'category == "timeline-zoom"'` 实时看
   （`Logger` subsystem 为 `com.srtflow.SrtFlow`；注意 **`log show` 事后查
   ad-hoc 签名的调试拷贝一条都查不到**，只能 stream）。缩放范围 4–4800（`VideoEditZoom`，
   超宽内容的绘制约束见 [波形与深度缩放](audio-waveform.md)），缩放滑杆是**对数刻度**。
5. 回归面：普通横向滚动、片段点选/拖动不得受影响（monitor 对非捏合、非 Ctrl+滚轮一律 `return event`
   放行；右键 / ⌃ 点只记位置、原样放行）。

**人工回归清单**（真捏合只能手测，发版前过一遍）：

- [ ] 滚到时间线中间某处，鼠标停在某段素材的某一帧上捏合放大 / 缩小：那一帧一直在鼠标底下，两边往外 / 往里收，
      不往一边跑；滚到最右边（工程末尾）再放大也一样。
- [ ] 贴着 0 秒缩小：内容贴左（预期的例外）。
- [ ] 按住 ⌥ 捏合：所有视频轨和音频轨一起变高 / 变矮、一样高，鼠标指着的那一行不上下跑；字幕、文字、形状、滤镜
      那几条细行不变。捏到一半松开 ⌥，仍然是纵向。
- [ ] ⌘↓ / ⌘↑ 一档一档地变高 / 变矮；在输入框里按是光标移到头 / 尾，不缩放。
- [ ] 纵向缩放后单独拖某一条轨的下边缘：只动那一条；再纵向缩放一次：又全部一样高。存盘重开，高度还在；⌘Z 撤的
      不是行高。
- [ ] 放大到要上下滚，滚下去：标尺和左边的总推子钉在顶上，块从标尺底下穿过去，不画到刻度上面
      （[案例](../bugfixes/2026-09-26-tracks-cover-pinned-ruler.md)）。
- [ ] 工具栏放大 / 缩小、⌘= / ⌘-、拖缩放滑杆：播放头在视口里时它不挪窝；播放头滚出视口时，视口正中那一刻不挪窝。
