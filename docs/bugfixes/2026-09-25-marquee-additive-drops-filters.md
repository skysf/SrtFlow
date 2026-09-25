# 2026-09-25 ⌘ 拖框加选，把原来选中的滤镜段丢了

## 症状

选中一段或几段滤镜，按住 ⌘（或 ⇧）在空白处拉框去加选别的段：松手之后框里的都选上了，**框外原来
选中的滤镜段却不再是选中的**。剪辑、形状、文字、字幕 cue 都没这个问题，只丢滤镜段。

不是用户报的：同一天上午滤镜段刚进框选、⌘A 和多选（652cbfc，还在 `feat/sound-scenes` 分支上、
没进 main），下午做[拖动会话搬出时间线的 @State](2026-09-25-drag-session-in-timeline-state.md)
时读代码读出来的。

## 根因

`TimelineMarquee.Hit`（一次框选的结果）的五类都带默认值 `= []`。滤镜段进框选时给它加了第五类
`filters`，可**逐类拼一个 `Hit` 的两处都没跟上**，又都照样编得过：

1. `Hit.union`（加选 = 起手前的选择 ∪ 框里的）只并了四类，`filters` 落到默认值 `[]`；
2. 拉框起手时记下的 `base`（起手前已有的选择，`beginMarquee`）也只收了四类，
   `project.selectedFilterIDs` 根本没进来。

任何一处漏都会丢，两处都漏了。当时的自检只验了「框能框中滤镜段」，加选的用例只造了剪辑 ——
滤镜那一类是空的，并集丢没丢看不出来。

## 修复

- `Hit` 的五类**去掉默认值**，空的用扩展里的 `Hit()`（写在扩展里，逐类列全的成员初始化器才留得住）。
  从此逐类拼 `Hit` 的地方漏写一类就编不过 —— 这正是这次两处漏掉的样子。
- `union` 并上 `filters`；`beginMarquee` 的 `base` 带上 `project.selectedFilterIDs`。

入口：`Sources/SrtFlow/VideoEditTimelineMarquee.swift`、`Sources/SrtFlow/VideoEditTimelineMarqueeGesture.swift`。

## 验证

- `scripts/check-timeline-snap.sh`：框选那一组从 `main.swift` 搬进 `checks/TimelineSnap/Marquee.swift`
  （`main.swift` 登记过超标、只许降），加了三条：加选时框外原来选中的滤镜段要留着；空手拖框连滤镜
  一起丢；`union` 并上空的、空的并上它都得原样回来 —— 夹具的每一类用 `Mirror` 数过都不许是空的，
  `Hit` 以后再加一类而夹具没跟上，这里先红。403 项全绿。
- **反向验证**：`union` 去掉 `filters` 那一行 → 自检编不过（`missing argument for parameter 'filters'`）；
  `union` 写成只留自己的 `filters` → 「空的并上它 = 它」红；`beginMarquee` 的 `base` 去掉 `filters` →
  App 编不过。恢复后全绿。
- 真窗口验不了：⌘ 拖框判加选读的是 `NSEvent.modifierFlags`（此刻键盘上真按着什么），进程内冒烟
  驱动合成的事件带不进去，驱动出来的都是不加选的那一种（实测：带 `flags: ["cmd"]` 的拖框照样把
  选择整个换掉）。已写进 [GUI 冒烟流程](../testing/gui-smoke-testing.md)「四之六」第 4 条，别再当成 bug。

## 教训 / 防回归

- **带默认值的字段 + 成员初始化器 = 加字段时编译器一声不吭。** 逐字段拼、逐字段拷的函数（并集、
  合并、转换）会悄悄漏掉新字段。这种「每一类都得列全」的值类型别给默认值，空值单独给一个初始化器；
  再给它配一条「每个字段都非空」的往返自检（用 `Mirror` 数字段，夹具漏了一类也红）。
- 给一个按类列举的集合加一类时，把**每一处**逐类列举的地方都 grep 一遍（这里是 `cues:` 出现的
  每一处），不要只改看得见的那几处。
- 长期约束写进 [拖动手势 §3.5b](../architecture/timeline-drag-gestures.md)（`Hit` 不给默认值）。
