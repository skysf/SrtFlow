# 2026-09-24 点一下选段卡半秒、拖块和滚动都跟不上手：时间线上每个块都订阅着整个工程

## 症状

用户在 70 多段素材、74 条字幕的工程（南极那份）上报「卡」：点一下选中一段要停一下；拖一段
文字、拖一段音频，块跟不上手；横向滚动一下也顿。

用进程内冒烟驱动（`scripts/gui-smoke/in-process/run.sh`，见
[GUI 冒烟流程](../testing/gui-smoke-testing.md)「四之六」）在这份工程的拷贝上量，修前
（主线程 CPU / 视图 body 重算次数 / Canvas 重画次数）：

| 动作 | 修前 |
| --- | --- |
| 点一下选中主轨一段 | 601 ms / 604 次 / 62 次 |
| 拖一段文字 30 拍 | 1678 ms / 5913 次 / 992 次 |
| 横向滚动 30 拍 | 366 ms |

## 根因

三处，叠在一起：

1. **每个块都订阅整个工程。** `ClipBlockView`（剪辑块）和它里面的 `VolumeCurveOverlay`
   （音量线）都写着 `@ObservedObject var project`，只为了读轨道颜色、推子、当前工具、
   帧率这几个值。订阅的代价是：工程里**任何一处**变化（点选一段只改 `selection`）都让
   73 个块全部重算、61 条音量线全部重画（每条重画还要重新描边求并算一遍命中路径，约 16 ms）。
2. **块的输入里有闭包，SwiftUI 比不出「没变」。** 剪辑 / 文字 / 形状 / 滤镜块和标尺、转场
   卡片的初始化参数里都有 `onDragBegin` 这类闭包；没有 `Equatable` 的话 SwiftUI 只能按
   「输入是不是 POD」判，带闭包就永远当变了。时间线的拖动位移是它自己的 `@State`，拖动
   每动一下时间线 body 重算一次、ForEach 里全部块跟着重算一次。字幕 cue 直接写在
   `subtitleRow` 的 ForEach 里、连块都不是，74 条 cue 连同各自的提示修饰器每拍全重算
   （拖 30 拍，`InstantHelpModifier` 重算 2300 多次）。
3. **轨道头列拿的是整份行数组**（`RowSpec`），行不可比较，拖动每一拍整列轨道头（推子、
   电平表、行高把手）跟着重算；两个标尺视图同理。

另外自动保存每次都重建全部素材书签（主线程约 55 ms），修在
[自动保存每次重建书签](2026-09-24-autosave-rebuilds-bookmarks-every-save.md)。

## 修复

原则一句话：**块只收算好的值，自己比较，调用处套 `.equatable()`。**

- `ClipBlockView` 不再订阅工程：画面要用的几个值由时间线（它订阅工程）算成
  `ClipBlockContext`（轨道色、推子、当前工具、帧率）传进来；`project` 留着只调动作
  （选中、切、标记、右键菜单）。块实现 `==`，只比画面用得到的输入；闭包不比 —— 它们捕获
  的是时间线视图、读的是它的 `@State` 和工程对象，永远是最新的。
- `VolumeCurveOverlay` 同样不订阅，`activeTool` 由块传进来；命中区的路径在 body 里算一次
  传给 `VolumeLineHitShape`，不再每次命中测试都描边求并。
- `TextBlockView` / `ShapeBlockView` / `FilterBlockView` 加 `Equatable`，调用处套 `.equatable()`。
- 字幕 cue 从行里拆成独立的 `SubtitleCueBlockView`（新文件
  `VideoEditTimelineSubtitleCueBlock.swift`），同一套。手势本体进块，起手判据
  （`clipDrag == nil || movingCueID != cue.id`）和落地留在行里。
- `RowSpec` 拆到 `VideoEditTimelineRowSpec.swift`（`TimelineRowSpec`，`Equatable`），
  轨道头列不再每拍重算；`TimelinePinnedRuler` / `TimelineRuler` / `TransitionCard` 按值比较。
- 冒烟驱动：窗口 `ignoresMouseEvents = true`（人在用这台机器，真鼠标扫过冒烟窗口会把悬停
  和提示叫醒，数就不是脚本的了）；`perf` 快照多记一项 `event:project.willChange`（工程发了
  几次「要变了」——订阅工程的视图每一次都得重算，这个数比 body 次数更能说明谁在叫醒大家）。

## 验证

同一份工程拷贝、同一份步骤表（1180×740 窗口），修后连跑两遍数字一模一样：

| 动作 | 修前 | 修后 |
| --- | --- | --- |
| 点一下选中主轨一段 | 601 ms / 604 次 / 62 次 | 431 ms / 314 次 / 1 次 |
| 拖一段文字 30 拍 | 1678 ms / 5913 次 / 992 次 | 1087 ms / 346 次 / 0 次 |
| 空白处框选拖 30 拍 | — / 2467 次 / 1 次（cue 拆块前） | 618 ms / 247 次 / 1 次 |
| 横向滚动 30 拍 | 366 ms | 18 ms |
| 纵向滚动 30 拍 | — | 123 ms / 147 次 |

真窗口里（同一驱动，读 `state` 的数字）：点选、拖音频段（9.468 → 12.0 s）、拖文字、两边裁切
（各 0.833 s）、刀片切一刀（段数 75 → 76）、拖音量线上的点（-1.4 → +6.0 dB）、从转场库点卡片
上转场（`crossFade` 落到选中段）—— 全部照常。

守卫（`checks/preview-perf-wiring.sh` 新增一节，反向验证三条都红过）：

1. 七个块 / 标尺 / 卡片必须 `struct X: View, Equatable`；
2. 块所在文件不许有 `@ObservedObject var project`（音量线单列一条）；
3. 构造处必须紧跟 `.equatable()`（隔着注释、尾随闭包、别的修饰器都行，别的语句先来就算没套）。

分别撤掉剪辑块的 `.equatable()`、给文字块加回 `@ObservedObject var project`、给音量线加回
订阅 —— 各自点名报红；恢复后绿。`checks/timeline-drag-wiring.sh` 的字幕 cue 那几条改成
「手势在块文件里、行里必须用 `SubtitleCueBlockView`」，媒体拖入那一节顺手拆到
`checks/timeline-drag-wiring/media-file-drop.sh`（主文件是登记过的老超标文件，只许降）；
`checks/hover-pointer-style.sh` 的刀片十字改认 `context.activeTool`。

## 教训 / 防回归

- **视图订阅整个工程是「按需读几个值」的十倍价钱。** 这个仓库的 `VideoEditProject` 是一个大
  `ObservableObject`，任何 `@Published` 一动全体订阅者重算。列表里的每一项（块、行、卡片）
  都不该订阅它，只该收值；订阅留给一层（时间线本体、检查器）。长期约束写进
  [预览性能 ratchet](../architecture/preview-perf-ratchet.md)「时间线上的块」。
- **带闭包的视图不套 `.equatable()` 就等于没做 Equatable。** SwiftUI 对非 POD 输入的视图只按
  身份重算，闭包永远算变了。
- **量的时候把「一拍多少次」和「一次多贵」分开看。** body 次数降了十倍，CPU 只降了三分之一：
  剩下的是时间线 body 本身每拍重算一次带起的 AttributeGraph 更新和布局（`sample` 里 75%），
  它和「块重算」是两笔账。下一步（未做）：把拖动位移挪出时间线的 `@State`，让时间线 body
  在拖动中不重算 —— 要动 [拖动手势](../architecture/timeline-drag-gestures.md) §0 的规矩。
- **冒烟脚本的坐标要从同一窗口大小的截图上量，而且要避开块上叠着的东西。** 这次的「拖音频段」
  一开始落在了块上的音量线上（线带只有几 pt 宽，正压在块的中下部），拖的是线不是块；裁切把手
  选中时只有 5 pt 宽，差 1 pt 就点进了块里。截图裁一块放大再量，或先用 `hit` 步骤看落在谁上。
- 还留着订阅的：`ClipMarkerStrip`（标记帽子）、轨道头行、工具栏图标、检查器。它们每次工程变化
  都重算，但一次点选只各重算一轮，不是这次的大头。
