# 2026-08-06 原生字幕生成评审返工十连（+二至五轮共十四连）

首版实现（docs/plans/2026-08-06-native-subtitle-generation.md，Phase 1–5 一次
落地）评审抓出 10 个问题：5 个 P1、4 个 P2、1 个流程遗漏；此后四轮复审各抓
5/3/3/3 个，多数是上一轮修复自身的缺口。全部当日修复。连续多轮的共性教训
见文末。

## 症状

1. **长素材无法真正断点续跑**：缺口没切窗口，词流整段完成才写 sidecar ——
   一小时素材中途取消/崩溃丢掉整小时成果，进度长期停在 10% 后跳变。
2. **异步翻译写回过期状态**：翻译 await 期间切工程或改原文，旧译文照样
   写进当前工程并清 stale。
3. **纯音频工程指纹/边界错 + 入口被误禁**：音频 clip 的 `info` 为 nil，
   指纹三元组塌成常量（同路径换文件仍命中旧缓存）；素材边界取
   `group.first` 的短时长会截掉远处切片；面板还要求必须有主视频。
4. **听不到的声音也被转写**：只查了 `isMuted`，漏了 `mainHidden`、
   `lane.isHidden`、`volume == 0`。
5. **双轨编辑器静默丢编辑**：行内 `@State` 只在 `.onSubmit` 提交，
   Tab 走人/点别行/关面板都丢。
6. **模型安装失败泄漏 reservation**：先 reserve 后安装，安装抛错没人释放，
   反复失败耗尽语言槽位（本机上限实测 5）。
7. **生成后的翻译取消/失败被报成成功**：service 把一切吞成 0，任务照进
   `.done`，用户看到 "Generated N cues" 却没有译文。
8. **重叠字幕预览堆叠方向与烧录相反**：预览把最早 cue 放顶部，libass 把
   最早事件排最底。
9. **sidecar 不是真 LRU、没有完整性校验**：读取不 touch，常用旧缓存反而
   先被淘汰；损坏文件只靠「能否解码」兜底。
10. **流程遗漏**：冒烟中顺手修了「翻译成功无回执」，没按仓库规则补案例。

## 根因

- 1/9 是**方案写了、实现走样**：计划明确「每缺口落盘」「LRU」「校验」，
  实现时被「先跑通」心态简化掉了。评审对照方案逐条验收才暴露。
- 2/7 是**异步任务的经典失误**：跨 await 写回共享状态时没带
  documentGeneration/内容快照守卫；错误路径图省事返回了成功值的零值。
- 3/4 是**只用手头素材测试**：测试视频有 info、有主轨、无隐藏轨，
  这些分支从未被踩到。可听性合同在 CompositionBuilder 里本来就有先例，
  没去抄。
- 5 是把 `.onSubmit`（回车）当成了「编辑结束」的全集。
- 6 是 defer 注册时机在 throw 之后。

## 修复

- **1**：`TranscriptLedger.windows(_:maxDuration:)`（Core，新增 + 单测）把
  缺口切成 ≤120s 固定窗口；`TranscriptionTask` 逐窗抽音频→转写→
  `merge`→`TranscriptSidecarStore.save`，窗口两侧多抽 0.5s 上下文、入账按
  **词中点归属本窗**（与 5.3 边界合同同一规则，相邻窗不重不漏）；进度按
  窗口时长平滑推进。中途死最多丢一个窗口。
- **2**：`SubtitleTranslationService` 请求前快照 `documentGeneration` +
  每条原文文本；返回后 generation 不符整体丢弃，单条原文变了单条丢弃
  （保持 stale 等重译）。
- **3**：`TranscriptSidecarStore.fingerprint(forFileAt:knownBytes:knownDuration:)`
  回退磁盘 size/mtime；素材边界改取整组已知时长最大值；面板门槛改为
  「`TranscriptionTask.soundClips` 非空」（与任务同一份合同，纯音频工程可用）。
- **4**：`soundClips(in:)` 复刻 CompositionBuilder 的可听合同：
  `mainHidden` 跳主轨、`lane.isHidden` 跳整轨、`isMuted || volume <= 0` 跳 clip。
- **5**：行内字段加 `@FocusState`，失焦即提交 + `.onDisappear` 兜底再提交；
  依赖合同入口对无变化是 no-op（`perform` 的 `next != before` 闸门）。
- **6**：安装段包 do/catch，抛错先 `release(reservedLocale:)` 再 rethrow。
- **7**：service 返回显式 `Outcome`（translated/nothingToDo/cancelled/
  discarded/failed）；任务把翻译失败报成
  "Subtitles were generated, but translation failed: …"，取消如实报取消；
  面板只对 `.translated` 给回执。顺带发现任务闭包早退会跳过尾部清理，
  清理挪进 `defer`。
- **8**：预览拼行改**倒序**（合同序第一条落最后一行 = 画面最底），与
  libass 事件堆叠方向一致；`SubtitleOverlap.ordered` 本体不动。
- **9**：sidecar 换 checksum 信封（payload JSON 字节 + SHA256，读时校验）；
  `load` 命中 touch mtime，容量淘汰变成真 LRU。旧格式文件解不出信封 →
  自动作废重建（缓存可重建，不迁移）。
- **10**：即本案例；「翻译成功无回执」的修复（面板 `lastTranslatedCount`
  回执）一并记录在此。

## 验证

- `swift run SrtFlowCoreChecks` 290 项全绿（新增 windows 切分 3 项：切分、
  短缺口不切、总时长不变）；`check-project-file.sh` 87 项全绿；
  preview-composition / export-alpha 全绿；`swift build --arch arm64` 干净。
- 端到端行为（生成→翻译→双语预览）此前已真实窗口冒烟通过；本轮改动不触
  已验证路径的正确分支，触发条件（长素材、切工程、纯音频、隐藏轨、失焦）
  待 15.3 真实素材矩阵回归。

## 二轮复审五连（修复本身引入/漏掉的）

1. **P1 编辑器兜底提交反噬外部新值**：一轮修 5 加的 `.onDisappear` 提交，
   碰上「重译写回 → 行 identity 变 → 旧行消失」会把旧草稿再盖回去。
   修复：行内记基线（创建时的四个值），提交必须**同时**过 dirty（草稿≠基线）
   和 CAS（模型当前值==基线，外部改过就放弃草稿）。
2. **P1 单批翻译 Stop 无效**：批间检查对 ≤32 条的常见任务没有「下一批」。
   修复：每个 await 之后 + 最终 success 之前都复查取消标记；macOS 26 经
   `cancelActiveSession` 闭包落实 `session.cancel()`（只在 run 存续期持有
   取消通道，session 本体仍不出闭包）；取消后浮出的异样错误统一按取消收尾。
3. **P1 转写按旧时间线快照写回 + 切工程不取消任务**：裁切/移动/变速不改
   generation，快照映射照样写回。修复：分段拆到 `finalize`，**永远用写回
   时刻的当前 state** 重取音源映射；当前区间超出账本覆盖（新裁进未转写段）
   如实报「时间线已变，请重跑」（账本使重跑只补新缺口）；
   `invalidateDocumentGeneration` 挂钩主动取消转写与翻译任务。
4. **P2 单个丢失素材中断整任务**：按素材 do/catch 跳过 + `skippedAssets`
   面板明示，全部读不了才 failed（CancellationError 永远直穿）。
5. **P2 模型下载进度丢弃**：`AssetInstallationRequest.progress` 用 KVO 观察
   `fractionCompleted`，折进总进度 0.02–0.1 段。

## 三轮复审三连（二轮修复自身的缺口）

1. **P1 取消通道让 session 间接逃逸**：二轮修 2 把 `session.cancel()` 包进
   闭包存到 coordinator 单例 —— 存的是通道不是本体，但同样违反「session
   不进单例」合同。修复：`cancel()` 只清 configuration（translationTask 按
   `.task(id:)` 语义取消 action task），run 内用 `withTaskCancellationHandler`
   在**结构化作用域内**就地调 `session.cancel()`；检查点统一
   `cancelRequested || Task.isCancelled`。
2. **P1 取消穿不透模型下载**：`cancel()` 只掐了 analyzer 和翻译，
   `.preparingModels` 阶段两者都不存在，旧任务占串行槽到下载结束。
   修复：`cancel()` 补 `runner?.cancel()` + `installProgress?.cancel()`
   （下载类 Progress 的标准取消通道，onProgress 回调时存下、用完清）；
   下载抛出的取消类错误归一成 CancellationError。
3. **P2 逐素材 catch 面过宽**：AV 读取和 `service.transcribe` 包在同一个
   catch 里，Speech/模型/临时目录故障都被报成「素材不可读」。修复：
   AudioWindowReader 拆 `ReadError`（素材的错，可跳过）与
   `InfrastructureError`（我们的错：临时文件建不了/写不进 —— 直接失败保留
   原因）；任务里只有**抽取**一步的素材错误触发跳过，转写错误一律直穿。

## 四轮复审三连（三轮修复的边角）

1. **P1 action 起跑前取消 → continuation 永久悬挂**：三轮修 1 把取消改成
   「清 configuration 让 SwiftUI 撤 action」，但排队期（SwiftUI 还没调
   run(session:)）取消的话根本没有 action 会来收尾 —— 调用方永远 await、
   isBusy 永远 true、后续翻译全被拒。修复：`actionStarted` 区分
   queued/running —— queued 取消**当场了结自己的 continuation**；再加
   `currentJobID`，finish/phase/checkpoint 只认对得上号的任务（被顶替的旧
   action 迟到收尾不许误伤新任务）。
2. **P1 安装成功与取消竞速仍漏 reservation**：release 的 defer 注册在
   「安装成功后的 token 检查」之后 —— 下载正常返回但取消标记已置位时，
   在 defer 存在前就抛了，service 的 catch 也不背这口锅（它没抛错）。
   修复：租约语义写死 —— **ensureModel 成功返回 = 调用方持有 reservation
   （「已安装」早退路径也统一 reserve）、抛错 = service 已自行释放**；
   调用方 defer+flag 先注册、成功即置位，任何后续 throw 都有人清理。
3. **P2 PCM 分配失败静默 continue → 永久音频缺口**：半截 CAF 照常转写、
   缺失区间被记成已覆盖，重跑也不补。修复：抛 InfrastructureError 整体
   失败（覆盖账目宁缺毋假）。

## 五轮复审三连（四轮修复的边角）

1. **P1 jobID 没随 action 传递**：run 进门才读「当前」currentJobID ——
   A queued→取消收尾→B 启动后，A 的迟到 action 会直接认领 B 的
   continuation/jobID（被顶替检测形同虚设）。修复：jobID 与 configuration
   **绑成 PendingJob 一起发布**，HostView 在同一次 body 求值里把两者捕获进
   action 闭包，`run(session:jobID:)` 进门先验明正身（对不上号/已起跑过
   直接退场）—— 与 Apple「session 绑定触发它的 configuration，换代即失效」
   的语义对齐。
2. **P1 释放 fire-and-forget 拆掉新任务的租约**：A 终态后 `Task { release }`
   还没跑，B 已 reserve（返回 false=已持有，Bool 被丢弃），随后 A 的
   release 移除了唯一的 app 级 reservation。修复：新增 `SpeechModelLeases`
   actor 做**引用计数**（acquire/release 严格配对，计数归零才真
   `AssetInventory.release`；reserve 返回 false 视为接管既有持有），
   且任务改为**所有出口 await 归还后才进入终态**，不再 fire-and-forget。
3. **P2 下载进度回调跨代复活旧状态**：onProgress 的 MainActor hop 可能在
   取消/清理/新任务启动后才落地，旧 Progress/KVO 写回新任务。修复：回调
   捕获本任务 token，赋值与 KVO 两处都按 `self.token === token` CAS，
   换代即丢弃。

## 教训 / 防回归

- **方案里写了的纪律，评审要逐条对照验收**——「每缺口落盘」「LRU」这种
  词出现在计划里，实现 diff 里就必须能指出对应行。
- **跨 await 写回工程状态，一律带 documentGeneration + 内容快照双守卫**；
  错误路径不许返回成功值的零值，用显式 Outcome。
- **generation 挡不住「同工程内改时间线」**：凡是「算完写回」的长任务，
  写回一侧要么用当下状态重算映射，要么对映射输入做 CAS —— 快照只配当
  转写输入，不配当写回依据。
- **「兜底提交」自身就是写回路径**，同样要 dirty + CAS 守卫；行 identity
  变化触发的 onDisappear 是最隐蔽的触发面。
- **取消检查的完备面 = 每个 await 前后 + 终态提交前**；「批间检查」对
  单批任务等于没有检查。
- **测试素材要覆盖 info == nil（纯音频）、隐藏轨、零音量**这些「用户手里
  常有、开发机上没有」的形态。
- **「可听性」只有一份合同**：以 CompositionBuilder 为准，新消费者抄它，
  不自己发明子集。
- `.onSubmit` ≠ 编辑结束；SwiftUI 行内编辑的提交面 = 失焦 + 行消失。
- @MainActor 任务闭包里 early return 前想一想尾部清理——统一 `defer`。
- **「不存 session」包括不存它的任何衍生闭包**：取消动作要留在 action 的
  结构化作用域里（withTaskCancellationHandler），驱动手段是 configuration/
  任务取消，不是把通道搬出去。
- **取消要逐阶段核对通道**：每个长 await（下载/分析/翻译）都得有对应的
  取消手段，光设标记等 await 自己回来不算取消。
- **catch 面 = 责任面**：跳过语义只配「确定属于该素材」的错误；
  系统性故障必须保留原始原因直接失败。
- **continuation 的收尾责任要按状态机点名**：谁在哪个状态负责 resume 得
  一一列举（queued → cancel 自己收；running → action 收）；「总会有人收」
  是悬挂的前奏。跨代任务用 job ID 认领，晚到的收尾一律作废。
- **资源清理的 defer 必须先于「成功后的第一个 throw 点」注册**；
  租约语义在 API 注释里写死（成功=谁持有、失败=谁已清理），别靠调用方猜。
- **覆盖类账本宁缺毋假**：任何「跳过一块继续」的路径都在把缺口记成已完成，
  要么抛错要么把该块从账目里扣掉。
- **身份要随触发源传递，不是事后去读「当前值」**：闭包/回调/action 在
  创建那一刻就该捕获自己的代次（jobID/token），执行时 CAS 核对；
  进门才读全局「当前」等于没有身份。
- **App 级共享资源（reservation 这类）不属于单个任务**：用引用计数的
  单一账本管理，acquire/release 严格配对；API 返回的所有权信息（reserve
  的 Bool）不许丢弃。
- **清理必须在终态之前 await 完成**：fire-and-forget 的清理和下一个任务
  的启动之间没有顺序保证。
- 连续多轮的共性：**评审要用「修复自身」当攻击面** —— 每一轮的修复代码
  引入的新分支（兜底提交、取消通道、跳过逻辑、defer 时机、身份检查）
  恰恰是下一轮 P1 的高发地，修完必须以同样强度再审一遍自己的 diff。
