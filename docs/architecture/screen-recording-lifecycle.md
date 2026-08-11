# 录屏生命周期：状态机、提交 journal 与请求快照

> 2026-08-07 随录屏 Phase 2 地基落地。案例背景（三轮复审各抓出什么）见
> [bugfixes/2026-08-07-screen-recording-foundation-review.md](../bugfixes/2026-08-07-screen-recording-foundation-review.md)。
> 类型都在 `Sources/SrtFlowCore/ScreenRecordingModels.swift`，自检在
> `SrtFlowCoreChecks/ScreenRecordingChecks.swift`。

## 状态机（`ScreenRecordingState`）

1. **写盘期（starting / recording / stopping）没有直达 `.failed` 的边。**
   `.failed` 是解锁工程切换的终态；stream/writer 出错也必须走
   `stopping → finishing`，把 stream、writer、manifest、控制窗收干净后由
   finishing 决定 `partialRecovery` 还是 `failed`。错误由 coordinator 随路携带，
   不靠状态编码。**给状态加锁只堵一半 —— 新增迁移边时必须审「会不会绕过锁态
   直达解锁态」**，自检里有全部反例。
2. **`.importing` 与 `.partialRecovery` 仍持有工程锁。** 文件提交完 ≠ 流程完：
   入轨事务未提交、partial 决策未做时切工程，素材会进错工程。
3. 工程切换（New / Open / Open Recent / Finder 打开）的**执行入口**必须再校验
   `locksProjectSwitching`，不能只靠按钮 disabled（计划 §3.4）。

## 提交 journal（`ScreenRecordingManifest` + `ScreenRecordingManifestStore`）

1. **每次 rename 之前先持久化意向**（committingMain / committingMicrophone），
   之后再推进到已提交阶段。协议全文见 `CommitStage` 的文档注释。
2. **持久化栅栏必须是 `ManifestStore.persist()` 成功返回，不许用 UserDefaults**：
   `UserDefaults.set` 内存立即生效、磁盘**异步**写入，「set 返回 → rename → 崩溃」
   时意向可能没落盘。store 用单文件原子写（写临时 + 原子 rename），persist
   返回后进程级崩溃（含 kill -9）不可能撤销。威胁模型是 App 崩溃，不含整机掉电
   （那需要 F_FULLFSYNC，计划未要求）。
3. **恢复裁决 = stage × 目录观察，不能只看 stage**：
   - committing 阶段靠 rename 的同卷原子性判定（临时还在 = 没发生；
     临时没了且最终在 = 发生了）；
   - 已提交阶段也要实测 final 是否还在 —— 在 → `committed`，
     不在（卷可达）→ `committedButMissing`，**如实报告，不拿别的文件顶**；
   - **「文件缺失」和「卷不可达」必须分开**：`volumeUnavailable` 时什么都不决定、
     不清 manifest，卷回来后重新裁决（`observationIsInconclusive`）。
4. **manifest 身份与四条路径全是 `let`，只有 `stage` 可变。**
5. 恢复只处理 manifest **点名**的精确路径（`owns(path:)`），禁止 glob；
   损坏的 manifest 文件 `load()` 抛错 → 如实报告，也不许退回 glob 扫描。

## 清账合同（`ScreenRecordingRecoveryLedger`）

**「文件现场」和「能否清账」是两件事，不许用前者代替后者。**
`FileResolution` 只描述现场（`observationIsInconclusive` 仅表示卷不可达）；
清 manifest 的唯一判据是 `canClearManifest` —— 每一路都要既**现场有结论**
又**处置已了结**（`RecoveryDisposition.settled`）。

必须保留 manifest 的典型场景（都有自检反例）：

| 场景 | 现场看起来 | 为什么不能清 |
| --- | --- | --- |
| writing 崩溃留下 partial，恢复 UI 还没弹/用户没选 | `notCommitted(tempExists: true)`，正常 | 清了账，那份隐藏临时文件就无人认领 |
| allCommitted 之后、入轨事务提交之前崩溃 | `committed`，正常 | 文件已是用户的但没进轨道，清了账再也提示不了 |
| 卷不可达 | 无结论 | 什么都断定不了，等卷回来重裁 |

`settled` 的含义：入轨成功、或用户明确选择「仅保留文件」/「删除」、
或错误已呈现并被确认。

**裁决必须两路都看，动作走纯函数。**
`ScreenRecordingRecoveryPlan.make(manifest:mainObservation:microphoneObservation:)`
是唯一的动作来源，产出 `waitForVolume / offerSalvage / offerImport /
reportMissing / discardTemporaries`。只按主文件裁决分支会把「主文件已提交、
麦克风临时文件还在」的可恢复录音当垃圾删掉；任一路卷不可达就整体
`waitForVolume`，不许半边裁决。清账只经 `clearManifest(plan:disposition:)`
这一个入口，判据仍是 `canClearManifest`。

**光有纯函数不算数 —— 要查它真的被生产代码调用了。**
`canClearManifest` 上一轮就写好并有自检，但整整一轮里生产代码一次都没调用过
（见 [Phase 2–4 复审](../bugfixes/2026-08-07-screen-recording-phase2-4-review.md)）。

## 文件覆盖与命名（`ScreenRecordingFileNaming`）

1. **验证在破坏之前。** 任何 rename/替换之前，先 probe **临时文件**；
   通过了才提交。反过来做，一个损坏的临时文件会先覆盖用户选中位置上的
   原有文件，之后才发现它不能用。
2. **只有主文件的覆盖是被授权的**（用户在 NSSavePanel 里确认过那一次）。
   麦克风 sidecar、崩溃恢复出来的文件一律
   `availableURL(like:isTaken:)` 避让到 `名字 2.ext`，绝不替换。
3. 临时文件不存在时**不许推进到 `committed` 阶段** —— 否则最终路径上的
   旧文件会被当成本次录制导入。
4. 按钮文案就是合同：「Keep file only」不得删除文件。删除只能由明确的
   Discard 触发。

## 退出协调

1. `prepareToTerminate()` 必须**穷举状态**，不能留 `default: return`：
   配置期（configuring / choosingSource / choosingDestination / preparing /
   countingDown）走 `invalidateSession()` 后放行，写盘期才 `.terminateLater`。
   静默 return 会让 `.terminateLater` 永远收不到 reply —— App 退不掉。
2. **reply 的值必须来自 `VideoEditProject.prepareToCloseDocument()`。**
   录制侧收干净不等于可以退出：未命名工程要问保存，自动保存有 2 秒防抖。
   收口在 `settleTerminationIfPossible()`，由 `transition()` 每次落到非忙状态
   时触发；`releaseResources()` 不得直接 reply（那会在 `.importing` 期间就答复）。
3. `start()` 每个 `await` 之后都要 `isCurrent(epoch)`：会话被撤销后，
   仍在飞行的 setup 流程会把刚清干净的 writer / manifest 重新造出来。
4. UI 的显隐要是**状态的投影**，不要第二份 `@State`。设置页 =
   `state == .configuring`；因此 `startRecording()` 里不能再 `dismiss()`
   （那会先把状态打回 `.idle`，`start()` 的入口 guard 随即失败）。

> 既有行为（非本模块引入）：**任何 sheet 开着时
> `applicationShouldTerminate` 根本不会被调用**，⌘Q 无反应。用 Export sheet
> 对照确认过。不是死锁，只是拒绝退出。

## 请求快照（`ScreenRecordingRequest`）

1. **全字段 `let`。** 叫快照就要类型上不可变 —— source、像素尺寸、帧率、
   generation 若可变，录制中就可能被改成互相不一致的组合。
2. **`sessionID` 无默认值**：进入 `.configuring` 时显式生成一次，贯穿 picker
   回调直到最终 request。`= UUID()` 默认值会让每个构造点各造一个身份。
3. 捕获像素尺寸开录前冻结（`capturePixelSize`），显示器中途换分辨率不追。
4. 临时文件名含**完整 UUID**（8 位短码在「残留 + 新会话」并存目录里会撞名）。
5. 麦克风是 `MicrophoneConfiguration.disabled / .device(id:)` ——
   设备 ID 是「开启」的固有组成部分，类型上不存在「开了但没设备」。

## 产物合同（`ScreenRecordingWriter` 交出去的文件）

下游（时间线预览、导出、缩略图）默认成立、生产端必须保证的两条：

1. **画面轨自己要盖到 T1。** 不是「容器时长到 T1」就算数 ——
   `AVMutableCompositionTrack.insertTimeRange` 只能取到画面轨真实存在的那段，
   差多少，预览和导出里就有多少纯黑。SCK 静止期只发不带像素的 idle 帧、一帧
   都不写，所以收尾必须由 `holdLastFrame(untilT1:)` 把最后一帧补到 T1。
   `endSession(atSourceTime:)` **不是补帧**：它只延容器时长，而且分片写入
   （`movieFragmentInterval`）下连最后一帧的时长都改不动。
   事故见 [录屏静止期尾部黑屏](../bugfixes/2026-08-11-screen-recording-idle-tail-black.md)。
2. **验收产物要逐轨看 `AVAssetTrack.timeRange`，不能只看 `asset.duration`。**
   播放器会把最后一帧冻在屏幕上播到容器末端，画面轨提前结束这件事在播放器里
   完全看不出来，只有进合成才现原形。同理，复现这类问题必须**按真实时间**跑
   并且**让第二条轨（电脑声音）持续在写** —— fragment 没被冲出去时，收尾还能
   把最后一帧延长，问题不出现。

## 自检纪律

- 每个守卫/断言组都要**反向验证**（注入该抓的错误，确认变红）。
- **自检覆盖的是「函数算得对不对」，不是「有没有被调用、调用时参数对不对」。**
  纯函数全绿之后，要另外查一遍生产调用点：Phase 2–4 复审的 8 个 P1 里，
  两个是「函数是对的，但没人调用 / 调用时给错了坐标系」。
  坐标类接线尤其危险 —— 主屏原点为零，给错坐标系在主屏上完全看不出来。
- 自检二进制的清理**不能用顶层 `defer`** —— 结尾是 `exit()`，而 `exit()` 不跑
  defer（previewcheck 曾因此攒了 52 个临时目录）。统一走显式清理出口。
