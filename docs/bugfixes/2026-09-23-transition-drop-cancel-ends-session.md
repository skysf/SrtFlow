# 2026-09-23 转场卡片拖到接缝上没反应：落点回了 `.cancel`，整轮拖放被取消

## 症状

把转场卡片（叠化等）从左栏拖到主轨两段之间的接缝上：没有落点框，松手什么也不
发生。**单击同一张卡片能直接应用到那条缝上**，所以不是「这条缝放不下这种转场」。

同一天里滤镜、音频库两套已经修好了（[落点被吞](2026-09-23-in-app-drops-swallowed-by-file-underlay.md)、
[类型没声明](2026-09-23-custom-drag-types-not-declared.md)），唯独转场还拖不进来。

## 根因

`DropProposal(operation: .cancel)` 在 SwiftUI 里的意思是「**取消这一轮拖放**」，
不是「这里不能放」。回过一次，之后 SwiftUI 就**再也不调** `dropUpdated`，松手只给
`dropExited` —— 指针挪到能放的地方也救不回来。「这儿不行、换个地方可以」对应的是
`.forbidden`（指针同样显示禁止号，拖放不断）。

转场代理一直是「附近没有可落的缝就回 `.cancel`」。以前它挂在主轨那一行上，只在
指针进了那一行之后才被问到，这个错不太露头。时间线改成只有一个落点
（`TimelineDropRouter`）之后，路由器在「转场不在主轨那一行」时也回了 `.cancel` ——
而拖动**总是**从别的地方进来的（左栏 → 标尺 → 轨道），第一拍几乎一定不在主轨上。
整轮拖放在第一拍就被取消了。

滤镜、音频库没中招，只是因为它们在内容区里从不回 `.cancel`（它们的 `.cancel` 只在
起手那一笔为空时出现，拖动中不会发生）。文件落点的 `.cancel` 只在「确知一个都
用不了」时出现，同样侥幸没露头。

### 日志（临时诊断，只记状态变化）

修之前，同一次拖动：

```
router validate payload=transition
router updated transition OFF-MAIN-ROW y=4      ← 从标尺那侧进来，回了 .cancel
router EXITED payload=transition at=(287.7, 53.1)   ← 松手时 y=53 明明在主轨（33…87）上
```

`OFF-MAIN-ROW` 之后一条 `updated` 都没有 —— 诊断按状态变化记，指针只要进了主轨
那一行就会多出一条 `onMainRow`。

改成 `.forbidden` 之后：

```
router updated transition OFF-MAIN-ROW y=10 … y=31     ← 禁止号，但拖放没断
transition target=nil x=244 → proposal=forbidden        ← 进了主轨，离缝还远
transition target=seam 0 d=0.5 x=248 → proposal=copy    ← 到了 40pt 以内
router PERFORM payload=transition at=(284.9, 65.3)      ← 落地
```

### 为什么之前没发现

- 合成事件驱动不了 SwiftUI 的 `.onDrag`，App 内拖放一直没有自动化验证。
- 用户第一次报「转场拖不进来」时，零余料的缝上叠化本来就放不下（那时的规则），
  现象和这个 bug 一模一样，我归到了容量上。改完容量、单击能应用、拖还是不行，
  这两个原因才分开。

## 修复

- 路由器和四个代理（转场、滤镜、音频库、文件）里「这里不能放」一律改回
  `.forbidden`，一处 `.cancel` 都不留。
- `checks/timeline-drag-wiring.sh` 第 1e 条：这五个文件里不许出现
  `DropProposal(operation: … .cancel …)`。

## 验证

- **用户实拖 A/B**：修复前后同一个工程、同一张叠化卡、同一条 12 秒的缝 —— 修复前
  没有框、松手没反应；修复后出框、松手落地。两次都带着诊断日志，证据见上。
- 守卫反向验证：五个文件各自改回一处 `.cancel` → 各自变红，恢复后回绿。
- `scripts/check-all.sh` 全绿。

## 教训 / 防回归

1. **`.cancel` 不是「不能放」。** DropProposal 里「这儿不行」要回 `.forbidden`；
   `.cancel` 会结束整轮拖放，而且没有任何报错，表现就是「拖过去没反应」。
2. **落点合并以后，每一套拖放都会先经过它不能放的地方。** 以前各自挂在自己那一行
   上时，「不能放」的分支很少被走到；合成一个落点之后，这个分支变成了每次必经。
   合并落点时要把每个代理的「不能放」分支都过一遍。
3. **现象一样不等于原因一样。** 同一个「拖过去没反应」，这一天里先后是四个不同的
   原因（被垫层吞、类型没声明、容量规则、`.cancel`）。每修一个都要让用户实拖确认，
   拖不过去就回到日志里看它卡在哪一拍，别凭上一次的结论套。
4. 长期约束：[时间线拖动手势 §5e-2](../architecture/timeline-drag-gestures.md) 第 7 条。
