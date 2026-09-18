# 2026-09-18 框选的框不跟鼠标：锚点用了一个滞后的滚动量

## 症状

用户报的两句话：

> 框选这个功能，有时候没有反应，有反应的时候，这个框又没有跟着鼠标，
> 比如鼠标在右边，框竟然在鼠标很左边的地方。

复现条件补问出来的三条（用户实测）：

- 时间线**拖到最左端（没横向滚动）时，框选完全正常**；
- 出问题时，框离鼠标的距离**大致等于横向滚过去的距离**；
- 拖块到视口边缘触发自动滚动的那一瞬间，块**不会**猛跳。

所以「有时候没有反应」和「框跑到左边」是同一件事的两个程度：滚得越远，框往左
偏得越多；偏到整个跑出视口，就看起来像「按下去什么都没发生」。而且那一路框中
的也是**错的那批块** —— 命中判定用的就是这个画歪了的矩形。

## 根因

框选是时间线上**唯一用绝对坐标**的手势。

- 手势坐标系钉在滚动视口上（`.named(scrollSpace)`），报的是指针在**视口**里的
  位置；框要画在**滚动内容**里。两者之间差的正是横向滚动量，所以
  `beginMarquee` / `applyMarqueePoint` 都要做一次 `pointer.x + scrollOffset`。
- 别的手势（块的移动、裁切、cue 的移动）吃的是 `translation` 这种**相对量**，
  自动滚动的补偿也是 `scrollOffset - originScrollOffset` 这个**差值**。同一个
  错误在它们身上会自己抵消 —— 所以滚动量错了，全 App 只有框选看得出来。

而这个 `scrollOffset` 是**异步观察**来的：滚动内容的 `.background` 里挂一层
`GeometryReader`，把 `-content.frame(in: .named(scrollSpace)).minX` 写进
`TimelineScrollOffsetKey` 这个 preference，再由 `.onPreferenceChange` 落进一个
`@State`。这条链路上的值什么时候到位，取决于 SwiftUI 什么时候跑完那一轮布局与
preference 传递；手势回调**不在**这条链路上，它读到的是「上一次传到的那个数」。

于是起手那一拍拿到的滚动量可能还是 0（或上一次布局时的值），框就整体画到指针
左边，偏差正好等于当时真实的滚动量。

**这不是「差一帧」的抖动**：注入验证里滚动量 ≈667pt 时，框整整偏了 ≈669pt ——
读到的基本就是初始值。

> 为什么拖块没露馅（用户实测的第三条）：`originScrollOffset` 和拖动中用的
> `scrollOffset` 来自同一个滞后的 `@State`，一减就抵消了。只有自动滚动那一路
> 会把 AppKit 的真值写回去，**如果**当时真的滚过一段，块才会跳 —— 从最左端
> 起拖的话滚动量本来就是 0，跳不出来。这条路径同样带病，只是更难撞见。

## 修复

**滚动量不再缓存，改为从 `NSScrollView` 现读。**

新增 `Sources/SrtFlow/VideoEditTimelineScrollGeometry.swift`：

- `TimelineScrollGeometry` 是整个时间线**唯一**碰 `NSScrollView` 的地方，
  `offsetX` 每次都现读 `contentView.bounds.origin.x`，另外提供
  `scrollHorizontally(by:)` 供自动滚动推。手势回调跑在主线程、和 AppKit 同一拍，
  读到的一定是此刻真正滚到哪儿了。
- `TimelineScrollViewAccessor`（原先在 `VideoEditTimelineDrag.swift`）跟着搬过来，
  现在同时把滚动视图交给几何入口和自动滚动的心跳。

接线侧：

- `beginMarquee` / `applyMarqueePoint` 用 `scrollGeometry.offsetX`；
  `applyMarqueePoint` 不再接收一个传进来的滚动量参数（少一个能传错的口子）。
- 四个拖动入口（剪辑 / 形状 / 文字 / 字幕 cue）冻结的 `originScrollOffset`、
  以及 `updateClipDrag` 每一拍用的滚动量，同样改成现读。
- `TimelineAutoScroller` 只剩心跳：推滚动交给几何入口，回调也不再传滚动量
  （`onScroll: () -> Void`）—— 传了就等于又多出一个「滚动量的来源」。
- 删掉 `TimelineScrollOffsetKey`、那层 `GeometryReader` 与 `.onPreferenceChange`，
  以及一个只写不读的死状态 `marqueeOriginScrollOffset`。
- `followPlayhead` 判断「播放头还在不在视野里」也换成现读值。

## 验证

**真窗口注入（docs/testing/gui-smoke-testing.md）**，修复前后各跑一次**同一套**
注入：10 秒素材 → Ctrl+滚轮缩放到 120 pps → 横向滚到底（滚动量 ≈667pt）→ 在
主轨尾部空白处按下 (1145, 558) 拖到 (1322, 600) 并**按住不放**截图。

| | 框的左/右边缘（屏幕点） | 与指针的偏差 |
| --- | --- | --- |
| 修复前 | 右边缘 ≈653，整个框贴在视口最左端 | **≈669pt，正好一个滚动量** |
| 修复后 | 左 1146 / 右 1322、上 558 / 下 599 | **≤1pt** |

修复前那张截图里，指针在视口右侧，框却画在 00:06–00:07 那一段上 —— 和用户的
描述逐字对上。

**扫描守卫**：`checks/timeline-drag-wiring.sh` 新增第 9 节（滚动量只有一个来源），
四条逐条反向验证过：

- `beginMarquee` 退回不加滚动量 → 红；
- 把滚动量缓存回 `@State scrollOffset` → 红；
- 四个拖动入口少一处现读 → 红（并报出「只有 3 处」）；
- 别的文件自己去摸 `clipView.scroll(to:)` / `contentView.bounds.origin` → 红。

`scripts/check-all.sh` 全绿。

## 教训 / 防回归

1. **手势要用的量必须是「此刻现读」，不能是「被观察到的」。** preference /
   `onChange` / `@Published` 这类链路的语义是「过一会儿会一致」，而手势回调要的
   是「这一拍就得对」。凡是拿来做坐标换算的量，宁可从 AppKit 现读。
2. **相对量能掩盖绝对量的错误。** 全时间线只有框选用绝对坐标，所以同一个坏掉的
   滚动量只在它身上现形；拖块那条路径其实一样带病，只是差值把它藏住了。查这类
   bug 时，先问「谁是唯一不做差的那个消费者」。
3. **「有时候没反应」可能只是「画到视野外了」。** 用户描述的两个症状（没反应 /
   框在左边）本来就是一个连续量的两端，别当成两个 bug 分头查。
4. 长期约束已写进
   [docs/architecture/timeline-drag-gestures.md](../architecture/timeline-drag-gestures.md)
   的「框选」一节与新增的「滚动量的唯一真相」一节。
