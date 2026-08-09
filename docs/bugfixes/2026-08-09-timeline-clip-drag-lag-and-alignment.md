# 2026-08-09 时间线拖块追不上光标 + 边缘对齐没有参考线

## 症状

用户报告两条，都是「移动轨道上的文件」这一个动作上的：

1. **块跟不上鼠标。** 拖着走的时候光标已经到了时间线最右边，块还在中间的位置，
   要停下来等它追上来。鼠标越快差得越远。
2. **对不齐。** 两个块的边缘明明碰到一起了，界面上没有任何提示。用户期望的是
   「最上面轨道的块移动时，和下面轨道的块边缘对上，出现一条垂直的对齐线」。

## 根因

四条独立的原因叠在同一个手势上，各自都能单独制造「粘、慢、对不上」。

### 1. 那条 0.12s 重排动画没豁免正在被拖的块

`ClipBlockView` 上挂着 `.animation(isTrimming ? nil : .easeOut(duration: 0.12),
value: clip.timelineStart)`。它本来是给**邻居**用的（磁吸重排时平滑挪过去），
但 `.animation(_:value:)` 会把该视图**所有**可动画属性一起animate —— 包括块
自己那个 `.offset`。而拖动中 `liveMove` 每一拍都在改 `clip.timelineStart`，
于是这条动画每一拍重定向一次，画出来的是「低通滤波后的鼠标」：手越快落后越多，
手一停它才追上来。

**这条约束当时已经写在
[timeline-drag-gestures.md](../architecture/timeline-drag-gestures.md) 里了**
（「动画豁免正在被拖的元素」），但代码只落实了裁切那一半 —— 上一次修裁切闪烁
时顺手加的 `isTrimming`，移动这一半一直没人补。**写在文档里的约束没有守卫
就等于没有。**

### 2. 拖动的每一拍都在写 `TimelineState`

`onDrag` → `project.liveMove` → `liveApply` → 无条件 `state = next`。而 `state`
的 `didSet` 会 `hasUnsavedChanges = true` + 重挂一次自动保存 Task，`@Published`
再把**整个编辑器视图树**（预览区、检查器、工具栏、所有剪辑块连同缩略图条和
波形 Canvas）标脏重建。时间线自己每一拍还额外写 `snapGuide` / `activeDrag` /
`dragTargetRow` 三个 `@State`。

单拍处理越久，AppKit 的 `mouseDragged` 队列积压越多，块就一直在补演历史事件 ——
这才是「光标到最右、块还在中间」里**大头**的那部分落后量。

### 3. 跟着一起动的伙伴还留在吸附候选里

`snap(_:excluding:)` 只排除被拖的块自己，没排除**跟着它动**的块（链接的音频、
多选的其他块）。这些伙伴上一拍刚被挪到手指底下，这一拍就成了「离落点只差几像素」
的候选，把块吸回上一帧的位置。表现是**鼠标走得越慢越粘**：一拍的位移小于 7 像素
就永远挣不脱。

### 4. 吸附只比「起点」，终点从来不参与

`snap` 拿 `proposed`（块的起点）去够候选，块的**终点**一次都没参加过比较。
所以「我的右边缘贴上你的左边缘」既不吸附也不亮线 —— 用户说的「两个边缘」里
有一个从来就没被实现过。

另外，参考线画在吸附后的位置、块画在**未吸附**的 `proposed` 上
（`dragVisualStart = max(0, proposed)`），两者本来就是错开的：线在一处、块在
另一处，松手块才跳过去。

## 修复

核心思路：**拖动过程中一个字都不写进模型**，块的位置在拖动期间纯粹是渲染偏移，
松手才一次性落地。

- 新增 `Sources/SrtFlow/VideoEditTimelineSnap.swift`（纯值函数，自检直接编）：
  - `TimelineSnap.resolve` —— 起点和终点**都**去够候选，所有配对里取位移最小的；
    落点先夹到 `minimumStart` 再算参考线，保证线和块画在同一处。
  - `TimelineSnap.alignedCandidates` —— 一次可以亮不止一条线（左右边缘各贴一个
    邻居）。
  - `TimelineSnap.candidates` —— 候选含 0 / 播放头 / 轨道末尾 / 所有**不动的**
    剪辑与形状的两端。「轨道末尾」也按留下来的内容算，否则拖最后一段时那条候选
    就是它自己的终点。
  - `TimelineSnap.mainInsertion` —— 主轨磁吸的插空位置。
- 新增 `Sources/SrtFlow/VideoEditTimelineDrag.swift`：`ClipDragSession`（一轮拖动
  的全部状态，候选在手势**开始**时冻住）、`TimelineAlignmentGuides`、
  `TimelineAutoScroller`（拖到视口边缘自动横向滚动）。
- `VideoEditProject`：`liveMove` → **`commitMove`**（走 `perform`，一步撤销、
  一次预览重建）；`snap(_:excluding:)` → `snapCandidates(moving:)`；
  新增 `movingClipIDs(draggedID:)`，让「谁在动」这份名单被候选、渲染、落地三处
  共用 —— 三处各算一份就是根因 3 的温床。
- `ClipBlockView`：去掉 `dragVisualStart`，位置改成
  `clip.timelineStart + (dragOffset ?? 0)`；动画同时豁免 `isTrimming` 和
  `dragOffset != nil`；移动手势的坐标系从 `.local` 钉到**滚动视口**的命名坐标系
  （块会在手指底下挪窝、自动滚动还会把内容抽走，两者都会污染以块自身为参照的
  translation）。形状块的手势同因同改。
- 产品行为按用户拍板改了两处：**主轨磁吸从「拖动中即时重排」改成「松手才归位」**
  （拖动中主轨其他块不动，只画一条青色插入指示线），以及**拖到边缘自动滚动**。
- `TimelineState.transitionOverlap(in:afterIndex:)` 抽成静态版本，让插入指示线的
  游标和 `packMain` 用**同一个**公式 —— 两份公式就是「指示线指这儿、松手跳别处」
  的定时炸弹。

## 验证

- **`scripts/check-timeline-snap.sh`（新，43 项）**，反向验证过三条：
  - 把 `resolve` 改回只比起点 → 5 项红（终点吸附、参考线全废）。
  - 把候选改回只排除被拖的块自己 → 2 项红（伙伴又成了参考点）。
  - 把插入游标的转场扣除去掉 → 2 项红（指示线和 `packMain` 分叉）。
- **`checks/timeline-drag-wiring.sh`（新，扫描守卫）**，钉住自检编不动的 SwiftUI
  接线，同样三条都反向验证过：动画不豁免 `dragOffset` → 红；`updateClipDrag` 里
  出现 `commitMove` → 红；手势坐标系改回 `.local` → 红（顺带抓出形状块那条也是
  `.local`，一并修了）。
- **`scripts/check-all.sh` 全绿（13 项）**，两条新守卫已并入。
- **真窗口注入冒烟**（`SrtFlowDev.app` + CGEvent，流程见
  [gui-smoke-testing.md](../testing/gui-smoke-testing.md)）：
  - 抓住块中心右拖 300pt，松手前截图：块中心落在光标位置**误差 1 像素以内**
    （修复前是肉眼可见的一大截）。
  - 主轨磁吸拖动：拖动中另一段纹丝不动，青色插入指示线出现在 8s 那条缝；
    松手后块正好落在指示线处 —— 指示线没说谎。
  - 把块拖上新建的画中画轨，再左拖让它的**右边缘**去够主轨块的右边缘：
    通高的黄色对齐线出现在 8s，块的右边缘吸在线上（这正是用户描述的场景，
    也正是修复前完全没有反应的那一种配对）。
  - 拖到视口右缘并停住 900ms：时间线自动横向滚动约 3.5 秒的量，块继续跟着光标。

## 教训 / 防回归

- **文档里的约束不配守卫，第二次照样踩。** 「动画豁免被拖的元素」白纸黑字写在
  架构文档里，代码只做了裁切那一半，没有任何东西会红。凡是这类
  「纯函数全对、接线接错就整个白搭」的约束，即使自检编不动 SwiftUI，也要落一条
  grep 级的接线守卫（`checks/timeline-drag-wiring.sh`）。
- **手势路径上不要写全局模型。** 每一拍改 `@Published` 的代价不是"多几次重绘"，
  而是事件队列积压 —— 落后量会随着拖动时间**累积**，而不是稳定在某个小值。
  拖动中的位置属于视图状态，落地才属于模型。
- **「谁在动」必须只有一份名单。** 候选、渲染、落地三处各算一次，迟早分叉；
  分叉的表现是「拖不动」这种完全不像根因的症状。
- **同一个量的两条计算路径就是定时炸弹**（这次是插入位置的游标 vs `packMain`）——
  与 [2026-08-08 主轨数组顺序](2026-08-08-main-track-array-order-black-frame.md)
  同一个教训的第二次现身。
- 长期约束（拖动中不写 state、动画豁免、手势坐标系、候选冻住）已并入
  [timeline-drag-gestures.md](../architecture/timeline-drag-gestures.md)。

---

## 复审 follow-up（同日，第一轮修复之上又抓出 2 个 P1 + 4 个 P2）

第一轮把「拖动中」修对了，**落地那一层没跟上**：位置在拖动中算一遍、在
`commit` 里又算一遍，两份算法一分叉，用户看到的和最终得到的就不是一回事。

### P1-1 `movingIDs` 没有贯穿到落地

`commitMove` 仍然逐块调 `clampedStart`，而它把**正在一起移动的块**也当成障碍。

- 同轨 A=[0,5]、B=[5,10] 两者多选、拖 A 到 4：拖动中显示 A=[4,9]、B=[9,14]，
  松手时 A 被**旧位置的 B** 顶回 0 —— 整组完全没动。
- 跨轨更明显：落地只 `relocate(draggedID)`，所有视觉上跟随的多选块/链接音频
  全部弹回。视频横向移动并换轨时，链接音频留在旧时刻 = **A/V 错位**。

修法：整组落地收进一个接收**冻结 `plan` + 单一 `delta`** 的纯值变换
`TimelineState.applyDrag`：碰撞只看不动的块、整组用一个 delta 不逐块夹取、
水平平移与跨轨 `relocateClip` 在**同一次 `perform`** 里提交（一步撤销）。

### P1-2 有转场时主轨插入线仍会说谎

`mainInsertion` 拿 `rest` 的**原相邻关系**算时刻，可插入之后相邻关系就变了。
A(10s，其后 2s 转场) + B(10s) 之间插一段 1s 的 M：按 `rest` 算是 8s，
而真正 `[A,M,B]` 打包时 A→M 最多只能叠 `min(2, 4.5, 0.45) = 0.45`，M 落在
**9.55s**。共享 `transitionOverlap` 不够 —— 必须先定插入下标，再在**最终数组**
上跑 `TimelineState.packedStarts` 取时刻，指示线和 `packMain` 共用这份完整布局。

### P2 四条

- **自由轨还有第二套隐藏落地算法**：拖动中只吸附，`commit` 才跑 `clampedStart`。
  A=[0,5]、B=[10,15]，把 A 拖到 9s 松手会被推到 5s。改成落点解析
  （`ClipDragPlan.resolve`）在**手势路径上**就把碰撞算进去，且语义从「弹到障碍
  另一侧」改成「**停在接触面**」—— 渲染即落点。
- **极端缩小时 1:1 跟手会重新坏掉**：捏合的 `setScale` 只查 `isFinite`，没落实
  4–120 的钳制；`pps = 0.5` 时位移换算被 `max(pps, 1)` 兜底 → 鼠标走 100px、
  块只走 50px。改成 `VideoEditProject.zoomRange` 一份区间，工具栏/滑块/捏合
  共用 `setPixelsPerSecond` 这个唯一入口。
- **自动滚动心跳缺取消兜底**：只在正常 `onEnded` 停。补 `deinit` +
  `dismantleNSView` + `onDisappear` + tick 里自查滚动视图还在不在，四条退路。
- **坐标系守卫假绿**：只查「有没有写 `coordinateSpace:`」，改成 `.local` 照样绿。
  收紧成必须是 `.named(VideoEditTimelineView.scrollSpace)`。

### 三个产品决定（用户拍板）

1. **弹性尾部**：只给真正支持自由落点的轨道（画中画/音频/磁吸关掉的主轨/形状）。
   拖到右缘时内容宽度按投影落点动态增加半个视口，松手由新 `duration` 接管，
   没落地就缩回。磁吸主轨不给 —— 它只能插进现有故事线的某条缝，扩太远反而把
   插入指示线滚出视野。
2. **形状拖动一并统一**：「形状很轻」不成立，它每一拍写的是同一个 `@Published
   TimelineState`，整棵编辑器视图和自动保存照样被触发。已达到仓库「同一个模式
   第二次出现就抽共享组件」的门槛，改成与剪辑共用 `ClipDragSession` +
   `ClipDragPlan`，落地走 `perform(rebuildsPreview: false)`。
3. **多选 + 主轨磁吸**保留「整组插入同一条缝」：保持相对顺序、落地后连续、
   其他轨的伙伴按主拖块**实际**最终 delta 平移（被占位也不许挤开 —— A/V 同步
   优先于避免重叠）。

### 这一轮的验证

- `scripts/check-timeline-snap.sh` 从 43 项扩到 **84 项**，新增的都跑**生产路径**
  （`ClipDragPlan.make` → `plan.resolve` → `TimelineState.applyDrag`，
  `commitDrag` 只是把第三步包进一次 `perform`）。四条反向验证都红过：
  指示线退回按 `rest` 算 → 复现复审给的 8.0 vs 9.55；障碍不排除同行伙伴 →
  整组位移变 0；跨轨不带跟随块 → 链接音频停在 4.0 而不是 10.0；
  给跟随块补一次 `clampedStart` → 音频被挤到 16.0 而不是 10.0。
- `checks/timeline-drag-wiring.sh` 扩到 7 组，新增「落地不许再解析一次」
  「正好一次 `perform`」「障碍要排除移动块」「缩放唯一入口」「心跳三条退路」。
- 真窗口注入复验：多选整组拖动**松手前后逐像素相同**（P1-1 + P2-3）；
  形状拖动亮黄线并吸在剪辑边缘、松手不跳（统一后的新路径）；
  弹性尾部把形状拖过原工程末尾（16s → 20s）并留在那里。

### 这一轮的教训

- **「拖动中」修对了不等于修完了**：一次交互有两条路径（渲染、落地），
  只要它们各自算一遍位置，就一定会分叉。正确的形状是**一份解析结果**
  同时喂给渲染和落地。
- **纯值化要做到落地那一层**。第一轮把吸附抽成纯函数就收手了，落地留在
  `@MainActor` 类里 → 复审给的两个 P1 场景自检一个都够不着。把
  `ClipDragPlan.make` / `TimelineState.applyDrag` 也变成纯值之后，
  同样的反例全都能写成断言。
- **反向验证没红，说明测试矩阵有洞而不是代码没问题**：给跟随块补
  `clampedStart` 第一次没能让自检变红（两套算法在那些用例上恰好同解），
  补了「伙伴落点被别的块占着」这一例才逼出分歧。
