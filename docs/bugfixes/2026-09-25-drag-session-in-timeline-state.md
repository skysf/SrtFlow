# 2026-09-25 拖块 / 拉框每一拍整条时间线重算一次：拖动会话住在时间线的 `@State` 里

## 症状

用户在 77 段素材、74 条字幕的工程（南极那份）上报「卡」的第二轮：上一轮
（[时间线上每个块都订阅着整个工程](2026-09-24-timeline-blocks-observe-whole-project.md)）把块的
body 次数降了十倍之后，拖一段文字、拖一段音频、拉框仍然跟不上手。

进程内冒烟驱动（`scripts/gui-smoke/in-process/run.sh`，1180×860 窗口，坐标从同一窗口的截图上量）
在这份工程的拷贝上量，修前主线程 CPU / 视图 body 次数 / 时间线本体 body 次数：

| 动作 | 修前 |
| --- | --- |
| 拖一段音频 30 拍（含松手重建预览） | 1122 ms / 806 次 / **37** |
| 拖一段文字 30 拍 | 1158 ms / 767 次 / **32** |
| 空白处拉框 30 拍 | 700 ms / 373 次 / **32** |

时间线本体每一拍重算一次（30 拍 = 30 次），`TextRowDropIndicator` 也是 30 次。`sample` 看主线程：
拖动中 `AG::Graph::UpdateStack::update()` 和 `-[NSView layoutSubtreeIfNeeded]` 占忙碌时间的大头，
`SrtFlowDev` 自己的符号只占零头 —— 活不在我们的代码里，在「时间线的 body 变了之后 SwiftUI 要把
整棵子树 diff 一遍、重新布局」里。

## 根因

拖动 / 拉框的**会话**是 `VideoEditTimelineView` 的 `@State`：`clipDrag`、`marquee`、`dragTargetRow`、
`textDropRow`、`movingCueID`。`updateClipDrag` / `applyMarqueePoint` 每一拍写一次，SwiftUI 就把时间线
的 body 整个重算一次。上一轮给块套了 `.equatable()`，块自己的 body 是省下来了，但：

1. **ForEach 的 diff 省不掉**：每一拍 SwiftUI 仍要把所有行、每行的所有块按身份对一遍，问每个
   `Equatable` 块「变没变」。150 个块每拍问一遍，本身就是一笔账。
2. **AttributeGraph 的更新和布局省不掉**：时间线 body 里的每一个 `@State` 读取都是图上的一条边，
   写一次整张图从时间线那个节点往下失效、重算、重新布局。这一层和「块重不重算」是两回事。
3. `TextRowDropIndicator` 拿 `rowLayouts()`（不可比较的数组）当输入，每一拍跟着重算；`contentWidth`
   读 `clipDrag.end` 撑弹性尾部，每一拍都在变。

「拖动中不写 `TimelineState`」（§0）挡住了模型；会话本身住在时间线的 `@State` 里，是同一个错误
在视图层的翻版。

## 修复

一句话：**会话搬进引用类型 `TimelineDragBox`，时间线持有不订阅，块和覆盖层各订阅自己那一份**
（docs/architecture/timeline-drag-gestures.md §0b）。

- 新文件 `VideoEditTimelineDragBox.swift`：`TimelineDragBox: ObservableObject` 装 `clipDrag`、`marquee`、
  `dragTargetRow`、`textDropRow`、`movingCueID`，外加两份给块订阅的值 `offsets`（谁在动、动了多少）和
  `marqueeHit`；每个写入口都**先比再发**。时间线 `@State var dragBox` 持有，body 里一个字都不读 ——
  和 `scrollGeometry` 同一个模式（§5c）。
- 新文件 `VideoEditTimelineDragOverlay.swift`：对齐线、磁吸占位框、跨轨占位框、目标轨描边、文字换行
  指示、框选矩形集中在这一张覆盖层，它 `@ObservedObject` 盒子，是唯一的订阅者。`mainInsertionSpan` /
  `crossTrackGhost` 从时间线搬进来，算法没动。
- 五种块（剪辑 / 形状 / 文字 / 滤镜 / 字幕 cue）不再把 `dragOffset` 当输入，改成
  `onReceive(drag.$offsets)` 收自己那份、变了才写自己的 `@State`；选中态 = `marqueeHit ?? isSelected`，
  `marqueeHit` 从 `onReceive(drag.$marqueeHit)` 收。**框里的和模型里的一样就记 nil**：首版直接记
  true / false，框一起手全部块从 nil 变成 false 各重算一遍，30 拍多出 ~300 次 body、128 次音量线重画。
- `contentWidth` 的弹性尾部改成时间线的 `@State var dragTailWidth`，按半个视口一档往上跳，一次拖动
  最多写几次。`dragTargetRow` 从元组改成 `DragRowTarget`（元组不可比较）。
- `VolumeCurveOverlay` 加 `Equatable`（输入里有 `project` 这个引用，SwiftUI 比不出「没变」），
  剪辑块里两处套 `.equatable()`：拖音频块时线不再每拍重画。
- 做这一轮时读出来的另一个 bug（⌘ 拖框加选把原来选中的滤镜段丢了）单独修、单独一个案例：
  [⌘ 拖框加选丢了滤镜段](2026-09-25-marquee-additive-drops-filters.md)。

## 验证

同一份工程拷贝、同一份步骤表，修后连跑两遍计数一模一样（CPU 是 debug 版、±5%）：

| 动作 | 修前 | 修后 |
| --- | --- | --- |
| 拖一段音频 30 拍（含松手重建预览） | 1122 ms / 806 次 / 37 | 885 ms / 751 次 / **10** |
| 拖一段文字 30 拍 | 1158 ms / 767 次 / 32 | 852 ms / 746 次 / **6** |
| 空白处拉框 30 拍 | 700 ms / 373 次 / 32 | 538 ms / 350 次 / **4** |
| 横向 / 纵向滚动 30 拍 | 18 ms | 18 ms |

时间线本体在一次拖动里只重算起手和松手那几次（点选、`perform`、重建各叫醒一轮）。剩下的 CPU 几乎
全在松手那一下：拖音频段那 885 ms 里，`composition.assetOpen` 63 次、`meters.tapCreate` 22 次、
`project.willChange` 6 次（每次都让 55 个提示修饰器、17 行轨道头、工具栏和检查器各重算一轮），
那是下一件事（松手不重建整个预览合成）。落点没变：音频段 9.468 → 12.0 s（吸附到 12），文字块
0.904 → 2.422 s、留在原行。

**每一拍到底多贵**（同一动作拖 30 拍和 120 拍，差值除以 90）：拖文字 **3.4 ms / 拍**、拖音频
3.4 ms / 拍、拉框 6.9 ms / 拍（debug 版）；固定开销（起手 + 松手）文字 773 ms、音频 1176 ms、
拉框 279 ms。**采样**（300 拍的拖动，`arch -arm64 sample <pid> 4`）：主线程忙碌时间里
`AG::Graph::UpdateStack::update` 约 42%、AppKit 的整棵 `layoutSubtreeIfNeeded` 约 26%、手势分发
（`sendEventToGestureRecognizers`）约 18%，我们自己的符号加起来不到 5%（`updateClipDrag` 含
落点解析约 4%）。第一版让全部块都 `onReceive` 位移时，`TimelineDragBox.offsets.modify` 一项就占
8%（Combine 往 150 个订阅者扇出）—— 改成只有成员订阅之后它降到 1% 以下，但总忙碌时间几乎没变：
剩下的活是 SwiftUI 对整棵子树的布局和 AppKit 对每个 NSView（每个块上的提示锚层就是一个）的
布局，不在我们的代码里。要再往下走得减少时间线里的 NSView 数（提示修饰器的锚层），另开一条。

守卫 `checks/timeline-drag-wiring/drag-box.sh`（从主守卫里 `source`，主守卫 980 → 972 行）钉着：持有不
订阅、五个名字不许回到时间线的 `@State`、弹性尾部一档一档涨、订阅者只有覆盖层（扫全部源文件）、
五种块各自收位移和框选命中、盒子先比再发、一轮结束清干净、拖动中只写盒子。**反向验证 14 条**
（撤一条修复、守卫点名报红、恢复转绿）：改 `@StateObject` 持有、加回 `@State var clipDrag`、剪辑块
不收位移、文字块选中态不看框、盒子不比就发、弹性尾部不设门槛、往 `TextRowDropIndicator` 里塞一个
订阅、`end()` 不清 cue 记号、松手不传目标行、cue 起手只比 id、`onDisappear` 不清盒子、
`updateClipDrag` 里写时间线状态、音量线不套 `.equatable()` —— 全部红过。其中「往别的文件塞订阅」
第一版守卫**没红**：它只扫时间线这一族的文件，改成扫全部源文件才红。

真窗口功能回归（同一驱动、1180×860、读 `state`，步骤表 `func860.json`）：点选主轨一段；拖音频段
9.468 → 12.0 s（吸附）；拖文字 0.904 → 2.422 s、留在原行；框选扫过 16–21 s 那段只选中它；右把手裁 1 s
（6 → 5 s）；刀片切一刀（77 → 78 段）；拖出音量点；跨轨拖到上层轨（16 s 那段到 `overlay0`）；插入缝停 0.6 s
松手新开一条音轨（9 → 10 条，块在新轨上）；⌘A（78 段、8 段文字、37 条 cue）与 ⌘⇧A；文字块拖到最上面新开一行
（行 3）—— 12 项全部照常。第一遍漏掉的两项后来补上了：转场卡片那一步排在跨轨之后、接缝已经不存在，
挪到点选之后立刻点 —— 那段的接缝上了 crossFade；拖字幕 cue 那一步起点写在窗口外（x 1220 > 1180），
其实没拖到，改到原文轨那条 cue 上（23.967 → 22.107 s，吸住）—— 译文同 id 同时间跟着走。
（顺带看见：接缝上有转场时，遮罩盖住两边块的裁切把手，那条缝上裁不了 —— 老样子，不是这次改出来的。）

## 教训 / 防回归

- **「一拍多少次」和「一次多贵」之外还有第三笔账：谁的 body 变了。** 块全部 `Equatable` 之后
  body 次数已经很低，但只要时间线本体每一拍重算一次，SwiftUI 就得把整棵子树 diff 一遍、
  AttributeGraph 从那个节点往下重新布局。要消掉它，拖动中**一个 `@State` 都不能写**在时间线
  本体上 —— 会话得住到时间线不订阅的引用类型里。
- **订阅的个数本身就是每一拍的账。** 150 个块各挂一个 `onReceive`，位移每发一次 Combine 就扇出
  150 次，占了拖动中 8%；只让成员订阅之后没了。同理框选命中只在变了时发。
- **量「每一拍多贵」要用差值法**（30 拍和 120 拍相减），别拿一次拖动的总数当每拍成本：一次拖动里
  起手、松手那几笔固定开销占大头，会把每拍那几毫秒淹掉。
- **订阅粒度要和变化粒度一样细。** 盒子里每一拍变的只有位移，就只发位移；块只收自己那份，还要
  把「和模型一样」折成 nil，否则订阅本身就把全部块叫醒一遍。
- **守卫扫的范围要和规则的范围一样宽。** 「只许覆盖层订阅」按时间线这一族的文件扫，往族外的文件
  塞一个订阅就漏过去 —— 反向验证抓到的。规则说「全仓只许一处」，就扫全仓。
- 长期约束写进 [拖动手势 §0b](../architecture/timeline-drag-gestures.md)；
  [预览性能 ratchet 第九节](../architecture/preview-perf-ratchet.md) 收尾那段改成已做。
- 还留着的：整轨换位（§5i）的会话仍是时间线的 `@State`，每一拍重算整条时间线；三套拖放
  （滤镜 / 音频库 / Finder 文件）的落点框也仍是时间线的 `@State`。
