# 2026-08-05 关键帧导出评审三连：覆盖用户文件、画中画边缘变暗、预渲染泄漏+无法停止

- **日期**：2026-08-05
- **来源**：PR #7（关键帧动画导出）合并前评审，三处未发布即修复
- **相关**：[keyframe-animation](../architecture/keyframe-animation.md)、
  [2026-08-04-prerender-avfoundation-pitfalls](2026-08-04-prerender-avfoundation-pitfalls.md)、
  [2026-08-04-transform-review](2026-08-04-transform-review.md)（临时名→校验→
  原子替换这条约定的出处）

## 一、[P1] 预渲染失败会删掉用户已有的目标文件

**症状**：用户覆盖导出（保存面板选了已有文件，比如重新导出同一个工程）。
这次导出因为预渲染失败（磁盘满、素材编解码问题、AVAssetExportSession 任何
一种失败……）中途报错——用户**原来那份能用的文件**也没了。

**根因**：`VideoEditExporter.export()` 的 catch 块对 `output`（用户选的路径）
无条件 `removeItem`，这个逻辑在预渲染功能加入前就有，但影响面很小：以前
`plan()` 只做同步的状态校验，几乎不会在 ffmpeg 起跑前失败。这次给动画段加了
AVFoundation 预渲染（真实 I/O、真实编码，失败模式多得多，耗时也长得多）之后，
`plan()` 会在 ffmpeg 从未碰过 `output` 的情况下失败，catch 块却依然把它删了。

更深一层：即便没有预渲染，ffmpeg 本身也是**直接拿 `-y` 打开用户选的路径**
（`args.append(output.path)`）——文件一旦打开就地截断，编码编到一半失败，
原文件早就没了，catch 块删的只是截断后的残骸。预渲染只是把「失败点提前、
失败概率变大」，洞本来就在。

**修复**：`VideoEditExportGraph.plan()` 新增 `Plan.tempOutput`，ffmpeg 实际
写 `workspace` 里的临时文件（扩展名跟真实输出一致，ffmpeg 靠文件名猜
muxer）；`VideoEditExporter.export()` 在 ffmpeg 退出码正常、临时文件确认
存在后，才用 `FileManager.replaceItemAt`/`moveItem` 原子替换到用户目标。
预渲染失败、ffmpeg 失败、用户点 Stop——所有失败路径都完全不碰 `output`，
连 `removeItem(at: output)` 这行代码都删掉了（不需要了）。跟
[2026-08-04-transform-review](2026-08-04-transform-review.md) 里黑底缓存的
「临时名→校验→原子替换」是同一个模式。

## 二、[P1] 动画画中画边缘发暗（预乘 alpha 被多乘一次）

**症状**：带旋转/缩放/不透明度关键帧的画中画，边缘抗锯齿处比正确画面暗一截
（越靠近半透明的过渡带越明显）。

**根因**：fill 中间片是压在黑底上合成出来的——边缘抗锯齿处的 RGB 已经是
`真实色 × coverage`（黑底=0，这就是预乘的定义）。ffmpeg 里 `alphamerge` 只是
把这份 RGB 原样接上 matte 给的 alpha，产物对 ffmpeg 来说是 straight alpha
语义，但数值其实是预乘过的。喂给 `overlay` 默认的 straight 混合
（`out = bg×(1-a) + fg×a`），边缘的 alpha 会被多乘一次
（`真实色×coverage×coverage`）。用项目自带 ffmpeg 手算验证：50% 覆盖、
黑底，正确值该是 ≈128，实测只有 ≈62。

**失败的修复尝试**（都实测验证过，不是猜的）：

1. 直觉认为该用 `overlay` 自带的 `alpha=premultiplied` 选项——查了
   `libavfilter/vf_overlay.c` 源码，这个选项确实存在，理论上正是为这种场景
   设计的。但实测：yuv420/rgb/gbrp 三种内部格式各配 straight/premultiplied
   跑了一遍，没有一组给出正确数值（premultiplied 模式下数值反而更不对）。
   往源码深处看，`overlay_straight` 取决于**帧的 `alpha_mode` 元数据协商**
   （`overlay->alpha_mode`），不是简单的「设了这个参数就按这个公式算」；
   `alphamerge` 不会给输出流打这个元数据标记，协商结果始终不是我们要的
   premultiplied。**这个选项在这张 filter 图上就是不生效，别在这个方向上
   继续试。**
2. 试过 ffmpeg 自带的 `unpremultiply` 滤镜（双输入，用第二路的通道去除
   第一路的预乘）。实测：无论怎么配 `planes` 参数，输出都约等于输入本身
   （压根没做除法），大概率是我对它的双输入协议用法有误，但没查清楚具体
   哪里错——没继续深挖，换了路子。

**真正的修复**：用 `blend` 滤镜的 `all_expr` 手动按 matte 把 fill 除回真实色
（`真实色 = 255×fill/matte`，`gt(B,0)` 挡除零），再 `alphamerge`——这样交给
`overlay` 的就是名副其实的 straight alpha，用它默认的混合公式就是对的。
实测多组颜色/背景组合（黑底/灰底、灰色/橙色、50%/25% 覆盖）都精确匹配手算
期望值。

**修复过程中额外踩的坑**：第一版实现里，matte 的 rgb24 版本（`blend` 要用
它做除数）是从 matte 的 gray 版本**派生**出来的（省一次解码）：
`[matte_gray] format=rgb24 [matte_rgb]`。这样接出来的图跑起来不报错、数值
也「看着正常」，但最终 alpha 会整段跑偏（128 实测变成 76，`blend` 那步本身
是对的，问题出在 `alphamerge` 读到的 alpha）。换成 matte 的 rgb24 版本
**独立**从原始输入转（`[matte_source] format=rgb24 [matte_rgb]`，跟 gray
版本各转各的，不共享中间结果）就正确了。原因没有查清楚（怀疑跟 `blend`
的 framesync 机制、或者两个下游共享同一路输入时的内部调度有关），但现象
稳定可复现——已经写进
[keyframe-animation.md](../architecture/keyframe-animation.md) 当硬约束，
`scripts/check-export-alpha-compositing.sh` 里第 2 项就是拿这个「省一次
解码」的写法当反例，确保它必须明显跑偏。

## 三、[P2] 预渲染阶段 Stop 无效，失败会泄漏大体积 ProRes 临时文件

**症状**（潜在，未见用户报告）：导出动画段较多或分辨率较高时，预渲染阶段
（`plan()` 内部循环调 `AnimatedClipPrerenderer`）可能耗时很长，这段时间点
「Stop」没有任何反应。若其中某条动画段预渲染失败，前面已经成功渲染的
ProRes 422 中间片（4K 素材单条可能几百 MB 到几 GB）连同 workspace 目录一起
变成孤儿，留在系统临时目录里。

**根因**：
1. `process`（`FFmpegProcess`）只在 `plan()` 跑完、ffmpeg 真正起跑前才赋值
   给 `VideoEditExporter.process`；`cancel()` 只会 `process?.cancel()`，
   预渲染期间 `process` 还是 nil，点 Stop 是空操作。
2. `workspace` 同理只在 `plan()` **成功返回**后才赋给
   `VideoEditExporter.workspace`（`workspace = plan.workspace`）。`plan()`
   内部预渲染循环是顺序 `try await`，某条动画段失败会让整个 `plan()`
   直接 throw、那行赋值永远不会执行——`VideoEditExporter` 的清理逻辑
   （`if let workspace { removeItem }`）拿不到路径，前面已经渲染完的中间片
   没人删。

**修复**：
1. 新增 `ExportCancellationToken`（`VideoEditPrerender.swift`）：预渲染阶段
   没有 `Process` 可 `terminate`，令牌持有当前正在跑的
   `AVAssetExportSession`（弱引用），`cancel()` 转发到
   `session.cancelExport()`；`AnimatedClipPrerenderer.render()` 起跑前也
   查一遍令牌，覆盖「两条 render 之间被取消」的窗口。`VideoEditExporter`
   在 `export()` 一开始就建好令牌，`cancel()` 里令牌和 `FFmpegProcess`
   两段都取消。
2. `VideoEditExportGraph.plan()` 里 workspace 一创建好，立刻用
   `defer` 挂一道兜底清理（靠一个 `workspaceOwnershipTransferred` 标记
   位判断是否已经正常return、调用方接手了清理责任），不再依赖调用方
   等到 `plan()` 成功返回才拿得到路径——`plan()` 自己对自己创建的临时
   产物负责到底，异常退出也不例外。

## 复审补刀（同日第二轮）

三处修复提交后又送了一轮评审，抓到三个新问题——两个是这轮修复自己带进去的
回归，一个是没收严的竞态。**都是复审专门在改动本身上找茬才挑出来的**：
第一轮的自检（数值比对）全过，因为没人测过「Stop 恰好点在 build() 期间」
和「fill 到底该不该带 opacity」这两件事。

### 四、[P1] Stop 点在 `build()` 期间会直接崩溃整个 App

**症状**：预渲染阶段点 Stop，时机恰好落在 `VideoEditCompositionBuilder.
build()`（本身要跑一段时间的 async 调用）执行期间——不是报错、不是取消
成功，是**整个进程直接退出**。

**根因**：`render()` 里，`cancellation?.isCancelled` 只在函数最开头查了
一次；`build()` 这段 await 期间用户点 Stop，`cancel()` 会把 token 标记为
已取消，但此时 `session` 还没创建，`register(session)`（旧版 API）登记时
发现「已经被取消」就会转发调用 `session.cancelExport()`——**对一条还没
调用过 `export()` 的会话**（状态仍是 `.unknown`）。复审实测：这一步让
`session.status` 变成 `.cancelled`，但代码接下来仍然会执行
`await session.export()`；对一条状态已经是 `.cancelled` 的会话调
`export()`，AVFoundation 内部断言失败，抛出 `NSInternalInconsistencyException`
——这是 Objective-C 异常，不是 Swift `Error`，**Swift 的 `do/catch` 完全
拦不住**，直接闪退。

**第一版修复（不彻底，第三轮评审打回）**：`register(_:)` 拆成
`beginSession(_:) -> Bool`（原子地「未取消才登记，已取消就返回 false」）
+ `endSession()`。当时以为把缝从「一次耗时几百毫秒的 `await build()`」
收窄到「几行同步代码」就够了，还在案例里写了段「残余风险，工程上可接受」
——第三轮评审指出这个判断站不住：

1. 崩溃路径**依然完整存在**：`beginSession` 登记完解锁 → 取消线程拿到
   session 调 `cancelExport()`（此时仍是 `.unknown`）→ 渲染线程接着执行
   `await session.export()` → 同一个不可捕获异常。窗口小不改变结局是
   「整个 App 崩掉」这件事。
2. 「几行不含挂起点的同步代码」这个说法本身就是错的——
   `await session.export()` 自带挂起点，从「检查完取消」到「底层导出真正
   起跑」之间隔着一次调度，没法证明取消线程插不进来。

**第二版修复（彻底）**：`beginSession` 改成
`startSession(_ session:, start:) -> Bool`——`start` 闭包（内部调
**回调式 `exportAsynchronously`**，它同步返回时导出已经真正开始）被放进
和 `cancel()` **同一把锁的临界区里**执行。这样取消线程拿到锁时只剩两种
世界，各自都安全：导出还没起跑（cancelled 已置位，`start` 永远不会执行，
会话直接被丢弃）、或已经起跑（`cancelExport()` 合法）。中间态在锁的语义
下不存在，不再是「概率小」而是「结构上没有」。特意不用 async 的
`export()` 正是因为它的挂起点让「启动」无法被包进任何临界区——这也是
为什么第一版怎么收窄都关不上。`exportAsynchronously` 在 macOS 15 起标了
弃用，但 deployment target 是 14，不触发警告；代码注释里写明了换新 API
时必须保住「启动在临界区内」的性质。

### 五、[P1] 新的除法公式把 clip 的不透明度设置抵消掉了

**症状**：50% 不透明度的画中画，导出后看起来几乎是全不透明的（远比预览里
淡的效果要重）。复审给的最小复现：深灰色内容 + 50% opacity 叠黑底，
应该输出约 `(32,32,32)`，实测约 `(63,63,63)`——刚好接近「不打折扣」的
数值，说明 opacity 设置在导出链路里基本没生效。

**根因**：这是修复「二」本身带来的回归。`renderOverlay()` 里 fill 一直有
这两行（**改「二」之前就在**，是为了配合当时 straight-overlay-直接吃预乘
RGB 的旧管线）：
```swift
fill.opacity = 1
if var animation = fill.animation {
    animation.opacity = KeyframeTrack()
    fill.animation = animation.isEmpty ? nil : animation
}
```
旧管线下这样做是对的：fill 是 `真实色×coverage`，matte 是
`coverage×opacity`，直接喂 straight overlay 会把两者相乘，opacity 若也算
进 fill 就会被两次压暗，所以刻意从 fill 里去掉。**但改「二」把管线换成
「先用 matte 除回真实色，再交给 overlay」之后，这个去掉 opacity 的动作
从「补偿」变成了「破坏」**：除法是 `255×fill/matte`，如果 fill 不带
opacity（`= T×c`）而 matte 带（`= c×o×255`），除出来的是 `T/o` 而不是
`T`——opacity 作为分母的因子被留在了结果里，最终合成时相当于把内容按
`1/o` 的倍数增亮，屏蔽了 opacity 该有的压暗效果。改「二」的实测（黑底/
灰底、灰色/橙色、50%/25% 覆盖）之所以没测出来，是因为那些用例里
**opacity 全部是 100%**（`o=1` 时 `T/o=T`，两种写法数值上没有差异）——
只测了 coverage 这一个维度，没测 opacity 这个维度，公式对 coverage 是对的、
对 opacity 是错的，测试覆盖不到就发现不了。

**修复**：删掉 fill 强制 `opacity = 1` 和清空动画 opacity 轨这两处，让
fill 跟 matte 携带**同一份** `coverage×opacity` 权重（`真实色×coverage×
opacity`），这样 `255×fill/matte` 分子分母的 opacity 因子能正确约掉，
recovered 出来就是纯真实色，跟 coverage、opacity 都无关。

### 六、[P2] ffmpeg 成功后、原子替换前还有一条没查的取消窗口

**症状**（潜在）：ffmpeg 已经跑完成功退出，用户几乎同一时刻点了 Stop——
这次 Stop 会被吞掉，导出仍然照常完成、文件仍然被替换，不算错误但违背了
用户的取消意图。

**根因**：`plan()` 成功返回、正式起跑 ffmpeg 之前，已经补了一次
`if token.isCancelled { throw CancellationError() }`（见「三」的修复）；
但 `ffmpeg.run()` **成功**返回之后、`replaceItemAt` 提交之前，没有对称地
再查一次。ffmpeg 进程这时已经退出，`process.cancel()`（内部靠
`Process.terminate()`）自然不再有效果，只有 token 还记得「用户点过
Stop」，但代码没去问它。

**修复**：在 `guard FileManager.default.fileExists(atPath: plan.tempOutput.
path)` 之前补上同一句 `if token.isCancelled { throw CancellationError() }`
——跟 prerender→ffmpeg 那道缝用的是同一个模式，这次把 ffmpeg→替换这道缝
也补上，两道缝都不留。

## 验证

- `swift build --arch arm64` 通过。
- `scripts/check-preview-composition.sh`（13 项，含更新后的 fill/matte 应
  携带同一份 opacity 的断言）全过，未回归。
- `scripts/check-export-alpha-compositing.sh` 补了第 3 组用例（全覆盖 +
  50% opacity，fill 带/不带 opacity 各一个断言）：全部 4 项断言通过
  （之前的 2 项 + 新增 2 项）。
- 「四」的第二版修复（启动进临界区）是并发正确性论证 + 编译验证，竞态
  窗口无法用自动化测试稳定复现——正确性依据是上面写的互斥论证（锁的
  语义下中间态不存在），不是「跑了很多遍没崩」。
- 覆盖导出、预渲染失败、导出中途 Stop（含 build() 期间点 Stop）这几条
  路径目前只做到代码走查 + 上述自动化验证，没有做真机 GUI 操作复现。
  真机层面的手动验收仍是后续 GUI 冒烟测试的待办——尤其「五」这类纯数值
  回归，真机上肉眼很难直接看出「淡了多少算对」，自动化数值比对目前是
  唯一现实的防线。

## 教训 / 防回归

1. **catch 块里「删掉 output」这种清理动作，要先问自己「这次失败到底有没有
   碰过 output」**，而不是不管三七二十一先删了再说。凡是「最终产物」的写入，
   一律走「临时名 → 校验 → 原子替换」，这条约定已经在
   [2026-08-04-transform-review](2026-08-04-transform-review.md) 里出现过
   一次（黑底缓存），这次是第二次独立踩到——同一个模式出现第二次，说明它
   该是团队默认做法，不是case by case 的补丁。
2. **给一段已有的同步代码接入新的、会真失败的异步 I/O（这里是 AVFoundation
   预渲染）时，原有的错误处理分支要重新过一遍**：以前「几乎不会走到」的
   失败路径，接入后可能变成「常走到」，原本无伤大雅的简化处理（比如无条件
   删文件）会被放大成真实风险。
3. **ffmpeg 滤镜图里「看起来更省一步」的写法（同一条流喂给两个下游）不能
   想当然当作安全的优化**——这次的 matte gray→rgb24 派生就是活生生的反例，
   数值跑偏但不报错、不崩溃，肉眼看滤镜图完全合理。**凡是这种「省一步」
   的改动，必须用真实数值比对（不是「跑起来没报错」）才能确认安全**，
   而且要把结论钉成自动化回归，不能只靠一次手工验证。
4. **官方文档写的 filter 选项不代表在你的具体图上真的按文档说的方式生效**
   （`overlay` 的 `alpha=premultiplied` 就是例子：选项存在、文档描述的方向
   也对，但依赖的元数据协商在这张图里从没被满足过）。涉及像素级正确性的
   ffmpeg 滤镜链，改完必须拿真实数值验证，不能凭 filter 名字和选项名字
   猜它「应该」做了什么。
5. **AVFoundation 这类有状态生命周期的对象（`AVAssetExportSession`、
   `AVAssetWriter` 都是），方法调用顺序错了往往不是抛 Swift `Error`，而是
   `NSInternalInconsistencyException` 直接崩进程**——`do/catch` 对这类
   异常完全无效。给这类对象接取消逻辑时，「取消」和「启动」的互斥必须把
   **真正的启动动作本身**包进临界区（这就要求启动是一个同步返回即已生效
   的调用，比如回调式 `exportAsynchronously`；async 包装的 `export()` 自带
   挂起点，结构上就放不进任何临界区）。「先原子登记、出临界区再启动」
   看似只差一步，缝还在——这次第一版修复就是这么打回来的。并发缝隙的
   修复不能用「窗口收窄了多少」来论证，要么给出「中间态在锁的语义下
   不存在」这类结构性论证，要么就承认没修完。
6. **修一个 bug 时的测试用例，容易只覆盖「这个 bug 涉及的那一个维度」，
   放过跟它耦合在同一个公式里的其他维度**——「二」的回归测试测了黑底/
   灰底、多种颜色、多种 coverage，唯独没让 opacity 有过除 100% 以外的
   取值，而「五」的问题恰恰只在 opacity≠100% 时才会现形。**改一条同时
   依赖多个输入维度的公式（这里是 coverage × opacity）时，回归用例要让
   每个维度都单独取到非平凡值（不能互相用 1 掩盖对方的系数），不能只
   验证「跟这次改动直接相关」的那一个维度。**
