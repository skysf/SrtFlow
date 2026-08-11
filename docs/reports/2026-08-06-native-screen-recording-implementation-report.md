# 原生录屏实施报告

> 计划：[docs/plans/2026-08-06-native-screen-recording.md](../plans/2026-08-06-native-screen-recording.md)
> 开始：2026-08-06
> 本报告在实施过程中持续更新。

## 1. 最终状态

**Partial** —— **Phase 0–5 主链路实机验证通过；计划 §17.4 的完整矩阵仍未跑完**。

**2026-08-08：主链路已由用户在真机上逐条走通。** 整屏录制、麦克风独立轨、
自定义区域（默认框 / 把手缩放 / 录制期遮罩）、保存位置预填与记忆、入轨事务，
全部实测通过。详见下方「§真机验收」。

仍未跑完的是计划 §17.4 的**完整**矩阵：窗口来源、多屏与混合 Retina、
真实崩溃（kill -9）恢复、睡眠/锁屏/切 Space 中断、长时（10 / 30 分钟）录制与
PCM 峰值对齐验收。按既定口径，这些没做完就不能写 Complete。

**2026-08-07 第二轮外部复审（Phase 2–4）已返工完毕**：8 个 P1 全部修复，
含一处直接的数据丢失（恢复弹窗写「Keep file only」实际删文件）、一处退出
死锁、一处无效文件覆盖用户目标文件。详见
[案例](../bugfixes/2026-08-07-screen-recording-phase2-4-review.md)与下方 §复审修正二。

状态口径：只有计划第 19 节全部满足、Phase 0–5 退出条件全部满足且必测项有真实证据，
才写 Complete。目前远未达到。

### 阶段进度

| Phase | 状态 |
| --- | --- |
| 0 权限 / API / 时钟 / 编码尖峰 | **完成**（3 项因本机环境或需人工交互而部分未覆盖，见 §4）|
| 1 macOS 15 基线 + 工程帧率 | **完成** |
| 2 来源选择和 UI 骨架 | **代码完成** —— 坐标换算/值类型 + picker adapter + 设置页 + 区域 overlay + 控制浮窗；真机 picker 交互未验 |
| 3 正式 capture + 主文件 | **代码完成** —— capture engine + 双 writer + coordinator 状态机 + journal 提交；真机录制未验 |
| 4 麦克风、入轨、退出回归 | **代码完成** —— 麦克风独立轨、单事务入轨、工程锁、`.terminateLater` 协调、崩溃恢复；真机未验 |
| 5 全量验证、文档、收尾 | **部分** —— 自动化验证与文档完成；真机 GUI/TCC/多屏/音频/长时矩阵**未跑** |

### 2026-08-07 复审修正二：Phase 2–4 的 8 个 P1

第二轮外部复审在「全部自检通过」之后读代码找出 8 个 P1。**当时的绿是真的，
但它只覆盖纯逻辑，这 8 个问题一个都不在纯逻辑里。**

| # | 问题 | 后果 | 修法 |
| --- | --- | --- | --- |
| 1 | 配置期 Quit 落进 `stop()` 的 `default:`；收尾后直接 reply 跳过 `prepareToCloseDocument()` | App 永久退不掉；未命名工程不问保存 | `prepareToTerminate()` 穷举状态 + `settleTerminationIfPossible()` 统一收口 |
| 2 | 先 commit 后 probe；临时文件不存在仍推进到 committed；sidecar 无冲突检查 | 损坏文件覆盖用户旧文件；旧文件被当成录制导入；sidecar 被静默替换 | 先验证临时文件再提交；缺文件抛错；`ScreenRecordingFileNaming` 避让 |
| 3 | 恢复只按主文件裁决；「Keep file only」实际删文件；`canClearManifest` 生产代码从未调用 | **直接数据丢失**；可恢复的 mic 录音被删；已提交未入轨的录制不再提示 | 三选一弹窗 + `ScreenRecordingRecoveryPlan` 纯函数 + ledger 唯一清账入口 |
| 4 | 停止无采样队列栅栏；`.started` 帧当 idle 丢；idle 帧时间戳不记；只查主 writer | append 与 finishWriting 竞态；丢首帧；静止画面录出 0 秒；mic 失败当成功 | 队列栅栏 + `isFinishing` + `observedEnd` + `finish(stopHostTime:)` + 单调 PTS |
| 5 | picker 前抢读 `SCShareableContent`；同尺寸双屏取 `first`；控制窗找不到仍继续 | clean TCC 首跑必废；录错屏；Stop 浮窗进成片 | 解析挪到回调后；15.2 用 `includedDisplays`，否则要求唯一否则报错；控制窗重试后失败 |
| 6 | 区域面板给全局 CG 坐标当 display-local `sourceRect`；窗口用主屏 scale | 副屏录错区域/越界；副屏窗口分辨率错 | 改调 `displayLocalRect`；改用 `filter.contentRect × pointPixelScale` |
| 7 | 设置页先 dismiss，错误只写页内；`ScreenRecordingError` 未实现 `LocalizedError` | 失败看起来像「点了没反应」；权限文案退化成错误码 | 新增 `report()` 同时写工程 notice；一律先试 `localizedText` |
| 8 | writer 先 start 后登记所有权；入轨失败仍无条件清账 | mic writer 失败时临时文件泄漏且无人认领；文件已存在却不再提示 | 先登记再 start；`importScreenRecording` 返回 Bool，失败保留 manifest |

**病根**：纯函数写对了但没被接上（#3 #6）、顺序错位（#1 #2 #5）、
状态机只覆盖正常路径（#1）、报错写到了看不见的地方（#7）。

### 同日第二轮：又 8 个 P1 + 3 个 P2

第一轮修完之后复审再读生产链路，找出 8 个**静态可确定**的 P1：

| # | 问题 | 后果 |
| --- | --- | --- |
| 1 | `ScreenRecordingProbe.info` 底下的 `MediaProbe` 无视频轨即抛错，却被用来探纯音频 sidecar；clip 又漏 `isAudioOnly`/`audioAssetDuration`；恢复导入完全忽略 mic | **麦克风轨永远进不了时间线** |
| 2 | `offerSalvage(main: nil, …)` 的 nil 被回退成主文件**临时**路径（已提交后不存在）→ probe 失败 → 走「救不回来」分支 | **删掉完好的 mic 录音并清账**（自检覆盖到的那一格） |
| 3 | 避让后的目标名在落 `committing` 意向**之后**才决定 | journal 记的路径与文件去处不一致 → 孤儿文件/认错文件 |
| 4 | `commitFiles` 抛错落到默认 `clearManifest: true` | 有效的 mic 临时文件永久无人认领 |
| 5 | `recoverIfNeeded` 挂在会重跑的 `VideoEditView.task`；`begin()` 不查未结清账本 | 录制中切回 Edit Video 会处理**当前正在写的** manifest；新录制覆盖唯一的账 |
| 6 | 恢复导入先清 `pendingRecovery` 再 await，期间是 `.idle`；无 generation CAS；partial 失败不清 `pendingPartial` | 素材可能进错工程；用户面对一个点了没反应的弹窗 |
| 7 | `didStopWithError` 先置空 `stream`，后续 `stop()` 在 guard 处返回 | **异常停止路径的采样队列栅栏整段跳过** |
| 8 | 收尾只 probe 视频；mic temp 缺失仍推进 `.allCommitted`；backlog 溢出不立即停、超时残留不计 partial | 音频失败被当成功 |

P2：固定比例矩形在屏幕边缘被裸 `intersection` 裁成任意比例；倒计时三秒
界面无任何显示；picker 未设 `allowsChangingSelectedContent = false`。

### 同日第三轮：5 个 P1 + 4 个 P2

| # | 问题 | 后果 |
| --- | --- | --- |
| 1 | 恢复三个断口：设 `pendingRecovery` 时不锁工程；`defer` 写成 `if isBusy` 而终点是 `.finished`/`.failed`；`stop()` 不处理 `.partialRecovery` | 等待决定期间可切工程；**Record Screen 永久无反应**；退出永远等不到 reply |
| 2 | `hasUnsettledManifest` 用 `try? load() != nil` | **损坏账本被当成没有账本**，下一次录制覆盖它 |
| 3 | 纯 mic 残留被塞进 `mainURL`；`commitRecovered` 提交无效主临时文件；Discard 只删 result 里的 URL | Add 注定失败；提交打不开的文件；留下孤儿 |
| 4 | mic writer 失败让 `start()` 抛错；两个 writer 共用一个 `failure` | **可选麦克风拖停整段主录屏** |
| 5 | 音频只验「有轨/时长>0」 | 麦克风录一个包就断也判成功 |

P2：收尾排空最坏 80 秒（改共享 3 秒墙钟 deadline）；倒计时清早了导致红点闪现；
`ScreenCaptureEngine` 无隔离读写（`@unchecked Sendable` 不消除竞争）；
比例夹取靠平移导致**锚点跳走**（改成先夹拖动点再算矩形）。

**全部已修**，589 = 586 + 3 断言。本轮实机验证：恢复框弹出时 Record Screen
disabled（锁工程）、已提交的残留不出现 Discard、点「Add to timeline」后按钮
恢复可用且能真正打开设置页（旧代码永久卡在 `.finished`）。

> 一次反证的额外收获：manifest fail-open 那条**起初没被抓到** —— 说明当时
> 根本没有守卫，补了 3 条断言后再反证才得到 2 条 FAIL。

**全部已修**，新增 27 条断言（555 → 582），三组反证均确认能变红。

**本轮拿到的实机证据**（植入账本 + AX 驱动，非纯逻辑）：

| 场景 | 结果 |
| --- | --- |
| `mainCommitted` + mic 临时文件在 → 启动恢复 | mic 临时文件**仍在**、manifest 保留、恢复框弹出（旧代码此时已删文件）|
| 恢复框点「Keep file only」 | `.Rec-Mic.PARTIAL.partial.m4a` → **提交成可见的 `Rec-Mic.m4a`**，主文件未动，账本了结（旧代码执行的是 `removeItem`）|
| `allCommitted` → 点「Add to timeline」 | 时间线出现主轨 `Rec` + **独立音频轨 `Rec-Mic`**，起点对齐；账本 settled（截图确认）|
| 设置页 Close | 状态回 `.idle`，页自动关、工具栏按钮恢复可用 |

**实机验证的一条**（插桩后真跑，`.choosingSource` 状态按 Quit）：

```
DIAG shouldTerminate isBusy=true state=choosingSource   ← 旧代码在此永久挂起
DIAG after prepare state=idle                            ← invalidateSession 生效
DIAG prepareToCloseDocument=true                         ← 旧代码完全跳过这一关
已退出
```

**新增 21 条断言**（534 → 555），覆盖 `ScreenRecordingRecoveryPlan.make` 的
stage × 两路观察矩阵与文件名避让；三条做了反证（把 bug 改回去确认变红）。

**顺带发现的既有问题（非本次引入，未修）**：任何 sheet 开着时
`applicationShouldTerminate` **根本不会被调用**，⌘Q 无反应。用与录屏无关的
Export sheet 对照确认行为一致，属全 app 既有行为。不是死锁，只是拒绝退出。

### 2026-08-07 复审修正（重要）

外部复审指出**几项测试把错误的契约写成了「正确答案」，形成假绿**。以下已修正
并补了反例守卫：

1. **工程格式 v5 逻辑错误** —— 原实现「默认 24fps 省略键并降级写 v3」。
   但 v4 及更早把帧率**硬编码成 30**，这样的文件在旧版会按 30fps 渲染，
   同一文件新旧版出不同成片，正是版本闸门要防的语义破坏。
   已改为**新版 writer 一律写 v5 且无条件落盘帧率**；回退只发生在读旧文件。
2. **多屏坐标翻转轴错了** —— 原用「屏幕并集顶边」，正确是**主屏高度**。
   实测对照：副屏 `NSScreen.frame.y = 900`、`CGDisplayBounds.y = -1080`；
   主屏高度 900 → `900-(900+1080) = -1080` ✓；并集 1980 → `0` ✗。
   原测试只验了错误公式**能自反往返**（错误公式同样自反），已改为
   对账实测值 + 校验结果真的落在目标屏 local bounds 内。
3. **alpha 的 24/30/60 是假参数化** —— 上一轮的脚本在 `write_text` 前抛了异常，
   替换根本没落盘，滤镜里仍是 `fps=30`，等于把 30fps 跑了三遍，而我报告成
   「三档全过」。已真正参数化（11 处）并补上计划要求的「独立 fixture、
   **不构成生产滤镜回归**」声明。
   **同时如实记录该测试的能力边界**：fixture 只取第一帧而 alpha 是逐帧数学，
   把帧率换成非法的 999 三档照样全过 —— 所以「不许写死帧率」由
   `checks/no-hardcoded-fps.sh` 扫描守卫兜底（已扩展到覆盖该脚本，并反向验证过）。
4. **磁盘阈值自相矛盾** —— 原为「开录 200 MB / 运行期警戒 500 MB」，
   刚过预检就会立刻触发主动停止；且偏离计划规定且无 Phase 0 数据支持。
   已回到计划的 `max(1 GiB, 两分钟估算)`，并加不变量
   `runtimeWarning < minimumRequired` 及其反例测试。
5. **撤销「麦克风固定后移 69 ms」** —— 见 §4 门槛 3 的订正说明。
6. **`SrtFlowCoreChecks/main.swift` 顶层塞不下更多断言** —— 近百条加进去后
   Swift 类型检查卡 20 分钟没编完（顶层脚本按一个作用域推断）。已拆到
   `ScreenRecordingChecks.swift` 的函数里，编译回到 3.7 秒。
   过程中我用错了 Python 切片（起点索引大于终点得到空串，
   `replace("", …)` 把内容插进了每两个字符之间），把该文件写成 177 万行 / 118 MB；
   已从 HEAD 还原并把检查重写进新文件，**没有丢失任何本会话之外的内容**。

### 2026-08-07 第二轮复审修正

第一轮列出的待办与第二轮复审新增的 3 个 P1 已全部完成：

1. **request 重建**：补 `sessionID`（无默认值，`.configuring` 时显式生成）、
   `documentGeneration`、冻结的 `capturePixelSize`、`cursor` 配置；麦克风建模成
   `MicrophoneConfiguration.disabled / .device(id:)`；**全字段 `let` 不可变**；
   临时文件名用完整 UUID（8 位短码有撞名概率）。
2. **状态机补齐 14 个态**，且**写盘期（starting/recording/stopping）没有直达
   `.failed` 的边** —— 错误也必须走 stopping → finishing 把 stream/writer/
   manifest/控制窗收干净，由 finishing 决定 partialRecovery 还是 failed。
   `.importing` / `.partialRecovery` 保持工程锁。
3. **manifest 改为 journal 式五阶段**（writing / committingMain / mainCommitted /
   committingMicrophone / allCommitted）：每次 rename 前先持久化意向，
   恢复用 `mainResolution` / `microphoneResolution`（stage × 精确路径的文件系统
   实况 → 裁决）判定，**七个崩溃切点全部有自检枚举**，含「rename 后、状态写入前
   崩溃」这个旧三阶段模型必然误判的窗口。
4. 本地化（`InfoPlist.strings` en/zh-Hans，已验证进资源包）、真实生产 ffmpeg
   24/30/60 回归（`check-export-frame-rate.sh`）、坐标完整落屏契约、
   守卫改文件系统枚举并补 `minimumFrameInterval` / `AVVideoExpectedSourceFrameRateKey`
   两条规则、`check-export-frame-rate.sh` 的 workspace 泄漏（15 个已清、复跑零泄漏）、
   canonical 计划回填实测订正、`docs/architecture/project-frame-rate.md` 落长期约束。

### 2026-08-07 第三轮复审修正（journal 层 3 个 P1）

1. **UserDefaults 不能当持久化栅栏**（内存立即生效、磁盘异步写入）→ 新增
   `ScreenRecordingManifestStore`：单 JSON 文件原子写，`persist()` 成功返回才许
   rename；自检绕开 store 直接读磁盘字节验证，损坏文件 load 抛错（不许退回 glob）。
2. **已提交阶段不再无条件 `committed`** → 裁决输入改 `DirectoryObservation`，
   区分「文件缺失」（`committedButMissing`，如实报告）与「卷不可达」
   （`volumeUnavailable`，不做决定；第四轮又把该判据改名为
   `observationIsInconclusive` 并另设清账合同，见下）。
   全阶段 × 卷不可达有自检覆盖。
3. **manifest 身份与四条路径改 `let`**，只留 `stage` 可变。
4. 三个自检二进制的「顶层 `defer` 被 `exit()` 绕过」泄漏修复（previewcheck 实测
   攒了 52 个目录、exportfps 8 个）；存量清零，复跑零残留（`find` 计数）。
5. macOS 14 分层的三处过期表述（字幕计划顶部 / AGENTS / 需求书 §4.9）按录屏计划
   §14.7 注明被全局 macOS 15 取代；报告「已知风险」里门槛 6 的「上限待实测」定案。
6. 长期约束落 `docs/architecture/screen-recording-lifecycle.md`。

### 2026-08-07 第四轮复审修正（清账合同）

**P1：`FileResolution` 只描述文件现场，被当成了清 manifest 的判据。**
后果：writing 阶段崩溃留下的 partial，现场是 `notCommitted(tempExists: true)`
看着无异常，于是允许清账 —— 但用户还没决定怎么处理它，清了就成孤儿文件；
同理 `allCommitted` 之后、入轨事务提交之前崩溃也会被放行。

修法：把「现场」和「流程」彻底分开。

- `blocksManifestRemoval` → **`observationIsInconclusive`**（只表示卷不可达），
  另加 `hasSalvageablePartial`。
- 新增 `RecoveryDisposition`（`pendingUserDecision` / `importPending` / `settled`）
  与 `ScreenRecordingRecoveryLedger`：**清 manifest 的唯一判据是
  `canClearManifest`** —— 每一路都要既现场有结论、又处置已了结，
  并给出可读的 `retentionReasons`。
- 自检补两个点名反例（恢复 UI 等待期间再次崩溃、allCommitted 后 import 前崩溃）、
  「卷不可达即便 settled 也不许清」、两路任一未了结即不许清。

另清掉 canonical 计划里**三处**仍要求 UserDefaults 的 manifest 合同
（§9.2 / §16 恢复矩阵 / §20 风险表），全部改为 `ScreenRecordingManifestStore`
并注明原因 —— 留着会直接诱导下一位执行者重新实现已被否定的方案。
（§7.3 「麦克风开关记入 UserDefaults」保留：那是普通偏好，不是持久化栅栏。）
报告偏差表补齐 canApply 定案、UserDefaults→Store、清账判据三条。

## 2. 环境基线（实测）

| 项 | 值 | 采集方式 |
| --- | --- | --- |
| 系统 | macOS **26.5.2**（Build 25F84） | `sw_vers` |
| 芯片 | Apple **M1** | `sysctl machdep.cpu.brand_string` |
| Swift | 6.3.3（swiftlang-6.3.3.1.3） | `swift --version` |
| 终端 target | `x86_64-apple-macosx26.0` —— **跑在 Rosetta 下** | `swift --version` |
| ScreenCaptureKit | 存在于 CLT SDK | `ls $(xcrun --show-sdk-path)/System/Library/Frameworks/ScreenCaptureKit.framework` |

终端在 Rosetta 下这一点与 `docs/build/build-and-packaging.md` 的警告一致：本项目
所有构建必须显式 `--arch arm64`，Phase 0 的 harness 也一样用
`-target arm64-apple-macosx15.0`。

### 显示器拓扑（决定门槛 10 的可测性）

```
id=1  origin=(   0.0,    0.0)  1440x900 点   1440x900 像素  scale=2.00  [主屏]
id=2  origin=(-279.0, -1080.0) 1920x1080 点  1920x1080 像素  scale=2.00
```

- **存在负原点副屏：是**（origin=(-279,-1080)）—— 门槛 10 的负原点用例可在本机复现。
- **混合 Retina：否** —— 两块屏 scale 都是 2.00。门槛 10 的「混合 Retina」子项
  **本机当前配置下无法覆盖**，需要人工把外接屏改成非 2x 缩放档再测。已列入 §11。

## 3. 本地代码核对（不依赖计划中的行号）

计划 §3 的断言逐条复核，结论：**基本准确，一处计数需修正**。

| 计划断言 | 实测 | 结论 |
| --- | --- | --- |
| `Package.swift` 是 tools 5.9 + `.macOS(.v14)` | `Package.swift:1` `// swift-tools-version: 5.9`；`:8` `.macOS(.v14)` | ✓ |
| `Info.plist` `LSMinimumSystemVersion` = 14.0，无三项用途说明 | `packaging/Info.plist:25-26` 为 `14.0`；三个 UsageDescription 键计数 = **0** | ✓ |
| `VideoEditCompositionBuilder` 固定 `frameDuration = 1/30` | `VideoEditCompositionBuilder.swift:677` | ✓ |
| `VideoEditExporter` **8 组**生产滤镜写死 `fps=30` / `r=30` | 实际 **9 处**：`VideoEditExporter.swift` 行 364 / 375 / 379 / 388 / 407 / 476 / 477 / 483 / 512（另 616 行是注释） | **修正为 9** |
| `KeyframeTrack.timeTolerance` 固定 `1/60` | `VideoEditAnimation.swift:21` `static let timeTolerance = 1.0 / 60` | ✓（文件名是 `VideoEditAnimation.swift`） |

`SrtFlowCoreChecks/main.swift:393,407` 也含 `fps=30`，但那是**测试期望值**不是生产
滤镜，改帧率时要一并更新，不计入生产扫描守卫。

## 4. Phase 0 硬门槛逐项结果

进度：**14 项门槛全部有实测结论**，其中 **11 项完整通过**，3 项因本机环境或需
人工交互而部分未覆盖（见下表）。另有 8 条附带发现直接改变产品实现方式。

| 门槛 | 状态 |
| --- | --- |
| 1 三来源 TCC 与权限边界 | **部分** —— TCC 机制已查清（4 条结论）；三条来源的 picker 交互需人工点击，未做 |
| 2 三路 format / PTS / 同步时钟 | ✅ 完整 |
| 3 双 writer / 共同 T0 / PCM 对齐 | ✅ 完整（测得 69 ms 恒定偏移并已拆解成分）|
| 4 长时累计漂移 | ✅ 完整（10 分钟 + 30 分钟，结论：无累积漂移）|
| 5 麦克风设备 | **部分** —— 显式 device ID 已验证；「无默认设备」本机无法制造 |
| 6 H.264 尺寸边界 | ✅ 完整（推翻计划的 `canApply` 方案）|
| 7 BGRA / 指针 / 点击效果 | ✅ 完整 |
| 8 自身进程音频 | ✅ 完整 |
| 9 控制窗排除 | ✅ 完整 |
| 10 多屏坐标 | **部分** —— 坐标系已确认 + 发现点/像素陷阱；`sourceRect` 网格待重测，混合 Retina 本机不可测 |
| 11 idle frame 与 endSession | **结论有误** —— 只量了容器时长就判「后备方案不需要」；补尾帧其实**必需**，2026-08-11 订正（见结论 B）|
| 12 ENOSPC 与 writer 状态 | ✅ 完整 |
| 13 崩溃后 partial 可恢复 | ✅ 完整 |
| 14 async 导出取消 | ✅ 完整（原有崩溃仍在，约束不得放松）|

**Phase 0 退出条件评估**：计划要求「三条来源的权限和排除策略可重复、双 writer
文件可重复生成、解码后 PCM 同步指标达标、Stop / ENOSPC / 崩溃后的 partial 可恢复」。
其中**双 writer、PCM 同步、ENOSPC、崩溃 partial 四项已达标**；
**三条来源的权限策略只完成了机制层面**，picker 交互未验证。

按执行约束 2，picker 那一项属于需要人工交互的实机动作，不是技术未知；其余门槛
均已全绿，且已产出 8 条明确的实现约束。**进入 Phase 1**，picker 交互留待
Phase 2 建出真实来源选择 UI 时一并做真机验证。

### 已确立的产品实现要求（Phase 1–5 必须照办）

这些是 Phase 0 实测得出、且**计划正文未写或写错**的实现约束：

1. **`writer.movieFragmentInterval` 必须设置**，否则崩溃丢整个文件（门槛 13）。
2. **音频不得在 `isReadyForMoreMediaData` 为假时丢弃**，要排队；溢出才判 partial（门槛 3）。
3. **录制期间必须持有 `ProcessInfo.beginActivity` 活动断言**，否则 App Nap 拖垮时长（门槛 3）。
4. **麦克风轨按共享 PTS 对齐，不做任何固定偏移**（门槛 2 已证三路同在 mach 时基）。
   实测到的 69 ms 是**声学链路**的本机观测值，含输出/扬声器/声程/输入/房间延迟，
   **不得写死进产品**（2026-08-07 复审撤销）。同时也不可按 2112 samples(44 ms)
   硬减 —— 实测 AAC 净贡献只有约 9.8 ms。
5. **三路 PTS 的 timescale 不一致**（mic 48000 / 另两路 1e9），比较前必须换算（门槛 2）。
6. **捕获尺寸必须用 `CGDisplayMode.pixelWidth/pixelHeight`（真实像素），
   不能用 `SCDisplay.width` 或 `CGDisplayPixelsWide`（都是「点」）**，
   否则在所有 Retina 机器上录成半分辨率糊图；再**等比缩到单边 ≤ 4096**，
   否则掉出硬件编码；不能按总像素判断（门槛 10 + 门槛 6）。
7. **`idle` 帧不带 image buffer 且占比可达 45%**，不能计作掉帧；产物是**变帧率**的，
   导入时长必须取容器时长而非帧数推算（门槛 11）。
   ⚠️ 2026-08-11 补：容器时长可信的**前提**是画面轨自己也盖到了 T1 —— 当年这条
   没验，静止期不写帧会让画面轨比容器短，导入后尾巴全黑。现在由
   `holdLastFrame` 补尾帧 + 产物复验保证（见结论 B 与
   [录屏静止期尾部黑屏](../bugfixes/2026-08-11-screen-recording-idle-tail-black.md)）。
8. **任何比色断言都要带容差** —— 捕获帧经显示器色彩配置转换（门槛 9）。

harness 结构（重要）：`~/Desktop/SrtFlowCaptureHarness.app` 是**永不重签的稳定
启动器**，它 `execv` 到 `~/.srtflow-phase0/payload`。这样改代码只重编 payload，
`.app` 的 cdhash 不变，TCC 授权不会失效（见门槛 1 结论 4）。已验证：重编 payload
后授权仍然有效。

### 门槛 6 — 5K / H.264 编码尺寸边界 → ✅ **已实测完成（结论与计划不同）**

**结论：M1 的硬件 H.264 编码器约束是「单边 ≤ 4096」，与总像素无关。**
超过任一边 4096 不是「不支持」，而是**静默掉进软件编码器** —— 对实时录屏意味着
CPU 飙升、可能掉帧和耗电，比直接失败更隐蔽。

产品规则（写回计划 §7.1 / §20）：**等比缩放到 width ≤ 4096 且 height ≤ 4096**，
不要用像素总数判断。

证据一，编码器身份（`VTCopySupportedPropertyDictionaryForEncoder` 的 `encoderIDOut`）：

```
[默认]     4096x2304  属性=132  encoderID=com.apple.videotoolbox.videoencoder.ave.avc   ← 硬件
[默认]     4200x2362  属性=70   encoderID=com.apple.videotoolbox.videoencoder.h264      ← 软件
[强制硬件] 4096x2304  status=0        ✓
[强制硬件] 4200x2362  status=-12903   ✗ kVTCouldNotFindVideoEncoderErr
```

证据二，二分定界 + 单边/总像素判定（`RequireHardwareAcceleratedVideoEncoder`）：

```
固定高 2304 → 硬件最大宽 = 4096
固定宽 4096 → 硬件最大高 = 4096
✓ 4096x4096  像素=16777216   ← 双边到上限，仍走硬件
✗ 5120x1440  像素= 7372800   ← 像素比 4K 还少，照样落软件
```

后者是关键反例：**超宽屏（5120×1440）像素数少于 4K，但因单边超 4096 而掉出硬件编码**。

证据三，本机实际显示器：

```
✓ 硬件   内建 2560x1600
✓ 硬件   LG 4K 3840x2160
✗ 落软件 假想 5K 5120x2880
```

计划原方案 `canApply` 预检**已证伪**：它对 1080p…8K（含奇数宽 1921×1080）**全部
返回 true**，只做设置字典的形状校验，不反映编码器能力。另注意 `canApply` 是
**实例方法**，预检需先有 writer 实例。实际写一帧并 `finishWriting` 的测试也全部
成功（8K 产物 7334 字节），进一步说明「能编」不等于「硬件编」。

<details><summary>原始记录：canApply 与真实编码</summary>

```
canApply：1080p/1440p/2560x1600/4K/5120x2160/5K/6K/8K/1921x1080 → 全部 ✓
真实编码写一帧：同上全部 ✓（8K 产物 7334 字节）
```
</details>

### 门槛 6 旧记录（已被上文取代）

计划原文（§20 风险表）：「5K H.264 尺寸不受支持 → `canApply` 预检并等比缩至已
验证尺寸」。

实测 `AVAssetWriter.canApply(outputSettings:forMediaType:)`（**注意它是实例方法，
不是静态方法**，预检必须先有 writer 实例）：

```
✓  1080p          1920x1080
✓  1440p          2560x1440
✓  4K UHD         3840x2160
✓  内建屏原生       2560x1600
✓  5K             5120x2880
✓  6K             6016x3384
✓  超宽            5120x2160
✓  8K             7680x4320
```

**全部返回 true，含 8K。** 也就是说 `canApply` 只做设置字典的形状校验，不反映
编码器的实际尺寸能力 —— **不能**用它当 5K 门槛。计划里这条 fallback 落空。

处理（按执行约束 7）：证据已记录在此；替代方案不改变产品范围（用户看到的仍是
「过大则等比缩到可用尺寸」），因此不停下确认，改为在 harness 里**实际编码**
探测真实上限，把结论写回计划 §20 与 §22。候选手段：
`VTCopySupportedPropertyDictionaryForEncoder` 查询编码器能力，或直接试编一帧。
**尚未验证，不作结论。**

### 门槛 1 — 三条来源的 TCC 与权限边界 → ⛔ **阻塞（需人工授权）**，但已得一条关键结论

**结论：从终端启动的子进程会继承终端的屏幕录制授权，因此终端里跑出来的任何
capture 成功都不能当作「App 自身已获授权」的证据。**

对照实验（同一个 `.app`，同一个 `env` 子命令）：

| 启动方式 | 结果 |
| --- | --- |
| 终端直接执行 `SrtFlowCaptureHarness.app/Contents/MacOS/SrtFlowCaptureHarness env` | 枚举成功：2 块显示器、48 个窗口、9 个应用，`RESULT=OK` |
| `open -a SrtFlowCaptureHarness.app --args env --out <log>`（自身 TCC 身份） | `SCStreamErrorDomain code=-3801 The user declined TCCs for application, window, display capture`，`RESULT=DENIED` |

两条附带结论：

1. **`-3801` 的文案是「user declined」，但用户从未看到过针对本 harness 的弹窗。**
   也就是说 SCShareableContent 对「尚未决定」的 App 同样返回 declined 语义的错误
   —— 计划 §17.1 第 1 项要求「不能把 picker 取消、来源消失或一般失败一律解释成
   屏幕权限拒绝」，这里补充一条对称的坑：**也不能把 -3801 直接解释成「用户明确
   拒绝过」**，它同样覆盖「从未授权」。产品文案要按「未获授权」写，而不是「你
   拒绝过」。
2. harness 当前是 `LSUIElement`（后台无 UI），未观察到授权弹窗自动出现；正式产品
   是有 UI 的前台 App，弹窗行为可能不同，需在 Phase 2 用真实 SrtFlow 复验。

**结论 2：`SCShareableContent` 不会触发授权弹窗，只会直接失败。**

前台 App（已移除 `LSUIElement`）下实测：未授权时 `SCShareableContent` 立即抛
-3801，**全程无弹窗**。产品**不能**指望靠它拉起授权，必须有显式的请求路径。

**结论 3：`CGRequestScreenCaptureAccess()` 同步返回值不可信，且对已拒绝状态不弹
「允许」弹窗。**

```
CGPreflightScreenCaptureAccess() = false      ← 只查状态，不弹窗，可安全用于 UI 判定
CGRequestScreenCaptureAccess()   = false      ← 立即返回，弹窗是异步的
再查 CGPreflightScreenCaptureAccess() = false  ← 同一进程内不会变
```

授权在**下次启动**才生效，所以产品不能在同一次调用里根据返回值决定后续流程。

**结论 4（重要，影响开发流程）：ad-hoc 签名的 App，TCC 授权会卡死。**

现象链：
1. 用户在「系统设置 → 屏幕与系统音频录制」里手动 `+` 添加 harness 并**打开开关**；
2. 该 App 自身身份下仍然 -3801 DENIED；
3. 再次触发时系统弹出的是**「已拒绝」变体**（只有 `Open System Settings` /
   `Deny`，**没有 `Allow`**），说明 TCC 内部状态是 denied，开关显示为开也不生效；
4. `tccutil reset ScreenCapture com.srtflow.captureharness` 重置后状态才回到未决定。

原因：`codesign --sign -` 是 **adhoc 签名、无 TeamIdentifier**（`codesign -dv` 确认：
`Signature=adhoc`、`TeamIdentifier=not set`），没有稳定的 designated requirement；
开发期反复 `--force` 重签会改变 cdhash，TCC 记录随之失配。

对本项目的直接影响：**SrtFlow 正式包也是 ad-hoc 签名**（见
`docs/build/build-and-packaging.md`），所以录屏授权在真实分发中很可能遇到同类问题。
这是一条需要在 Phase 2 用真实 SrtFlow 复验、并可能影响产品体验的风险，已记入 §11。

开发期规避：改动 harness 后如果授权失效，用
`tccutil reset ScreenCapture com.srtflow.captureharness` 重置再授权。

**尚未验证：** 三条来源（单窗口 picker / 整屏 picker + 控制窗排除 / 自定义区域）
各自的授权与错误行为、系统设置恢复行为、屏幕与电脑音频是否联合授权。全部等待
下方 §11 的人工授权动作。

### 门槛 2 — 三路 output 的 format / PTS epoch / 同步时钟 → ✅ **技术数据已实测**

> 这些数据取自终端启动（继承授权）的真实 capture。capture 确实发生，格式与时间戳
> 是真实的；**仅授权路径部分无效**（见门槛 1）。

**结论 A：`synchronizationClock` 与 host time clock 是同一时基，不同对象。**

```
CFEqual(synchronizationClock, CMClockGetHostTimeClock()) = 否
背靠背连读三次：
  #1 host=1747994.664854  sync=1747994.664854  差=+0.000000s
  #2 host=1747994.664881  sync=1747994.664881  差=+0.000000s
  #3 host=1747994.664893  sync=1747994.664894  差=+0.000000s
```

→ **不能用对象相等判断**，但数值可直接互换。计划 §20 担心的「mic 与 screen PTS
epoch 不同 → 需固化 offset 算法」在本机不成立：三路 PTS 都落在 mach 绝对时间域。

**结论 B：PTS 不是从零起算的**，而是 host clock 的绝对值（约 1747943.x s = 开机
以来秒数）。共同零点 `T0` 直接取 host clock 即可，三路无需换算 epoch。

**结论 C：麦克风的 timescale 与另外两路不同 —— 这是必须处理的差异。**

| 路 | timescale | 示例 PTS |
| --- | --- | --- |
| `.screen` | **1000000000**（纳秒） | `1748023953830000/1000000000` |
| `.audio` | **1000000000** | `1748023982756416/1000000000` |
| `.microphone` | **48000**（采样率） | `83909625673/48000` |

→ 代码**不能假设三路共用 timescale**，比较/相减前必须统一（`CMTimeConvertScale`
或直接用秒）。

**结论 D：格式**

```
screen     : video 1440x900 subtype=BGRA
audio      : 48000 Hz  ch=2  bits=32  fmt=lpcm  flags=0x29  → float32 非交错 立体声
microphone : 48000 Hz  ch=1  bits=32  fmt=lpcm  flags=0x9   → float32 交错   单声道
```

**结论 E：起始偏差**（同一次 capture 内）

```
screen.firstPTS - audio.firstPTS = -0.036266s  （第一次）
screen.firstPTS - audio.firstPTS = -0.028926s  （第二次）
```

→ 画面比系统声音早约 **29–36 ms** 到达。这正是计划 §8.2 要求「共同零点」的原因。

**结论 F：帧率配置生效** —— `minimumFrameInterval = 1/24`，3 秒得 72 个 screen
采样（24×3），精确吻合。

### 门槛 5 — 麦克风设备（部分）

设备枚举与**显式 device ID** 已验证可用：

```
Microsoft Teams Audio     uniqueID=MSLoopbackDriverDevice_UID
MacBook Pro Microphone    uniqueID=BuiltInMicrophoneDevice   [默认]
MJAudioRecorder           uniqueID=MJRecordDevice
```

以 `--mic-id BuiltInMicrophoneDevice` 启动，`.microphone` 路收到 387 个采样、
约 4.11 秒音频（`(83909822989-83909625673)/48000`），**显式 device ID 生效**。

**麦克风 TCC 弹窗把该次运行阻塞了约 93 秒**（screen 从 1748023.95 一直采到
1748121.33，而请求时长只有 4 秒），之后麦克风才开始出数据。事后查
`AVCaptureDevice.authorizationStatus(for: .audio)` = **authorized**。

> 授权是在这次运行中被授予的，但**我没有观察到是谁、以何种方式点的**，因此
> 不把它记为「已人工验证」。当前状态 authorized 是可复核的事实。

**尚未验证：** 44.1 kHz / 立体声麦克风、设备中途断开、无默认设备、
生成可导入的 AAC sidecar、mic gap 行为。

### 门槛 3 — 双 writer / 共同 T0 / 解码 PCM 验对齐 → ⚠️ **实测到 69 ms 恒定错位**

harness 用两个 `AVAssetWriter`（`.mov` 装画面+系统声音，`.m4a` 装麦克风），共用一个
`T0`（第一个到达采样的 PTS），三路写入前统一 `pts - T0`，收尾时两个 writer
`endSession` 到同一个 `T1`。

**测法**：按计划要求**解码成 PCM 比峰值**，不比容器 PTS、不减固定 2112 samples。
用 vendor/ffmpeg 造 6 秒 click 轨（每秒一声 1 kHz / 20 ms），录制中用 `afplay`
播放；系统声音数字捕获、麦克风声学拾取；麦克风路先 `bandpass=f=1000:w=200`
压掉环境噪声，再用 RMS 包络找峰。

**结果**：

```
系统声音(mov): 6 个 click @ 2.0104 3.0104 4.0104 5.0104 6.0104 7.0104   间隔精确 1.0000s
麦克风(m4a)  : 6 个 click @ 1.9421 2.9411 3.9411 4.9411 5.9411 6.9411   间隔精确 1.0000s

逐 click Δ(mic-sys): -68.29, -69.29, -69.33, -69.33, -69.31, -69.35 ms
平均 Δ = -69.153 ms
漂移(末-首) = -1.062 ms
```

**结论 A：麦克风轨内容比系统声音早 69.15 ms，且是恒定偏移。**
24 fps 一帧 = 41.667 ms，**69 ms ≈ 1.66 帧，超出计划的一帧预算**。

**结论 B：漂移可忽略** —— 5 秒内 1.06 ms。两路各自的 click 间隔都精确等于
1.0000 s，说明采样率与时基本身没有问题，**不需要**动态重采样或时间拉伸。

⚠️ 这条**不**等于「可以用常量补掉 69 ms」：那个数是声学链路的本机观测值。
见下方「结论订正」。

**结论 C：系统声音路本身是采样级准确的** —— 6 个 click 间隔 2.0104→7.0104，
5 个间隔跨 5.0000 s，**5 秒内漂移 < 0.1 ms**。

**结论 D：69 ms 的成分已拆清 —— AAC priming 只占 9.8 ms，其余是麦克风管线延迟。**

把两路音频都改成**未压缩 LPCM**（`kAudioFormatLinearPCM` f32，容器换 `.caf`）
重跑同一实验：

```
AAC  ：逐 click Δ = -68.29 -69.29 -69.33 -69.33 -69.31 -69.35 ms  平均 -69.153 ms
LPCM ：逐 click Δ = -58.35 -59.50 -59.50 -59.52 -59.52 -59.56 ms  平均 -59.326 ms
差值 = +9.827 ms  ← AAC 编码在两路上的净影响
```

拆解：

| 成分 | 量 | 说明 |
| --- | --- | --- |
| 麦克风管线固有延迟 | **≈ 59.3 ms** | 无压缩也存在，与编码无关 |
| AAC 净影响 | **≈ 9.8 ms** | 两路都过 AAC，priming 大部分抵消，残差来自立体声/单声道两条编码路径与容器 edit list 的差异 |
| **合计（产品实际用 AAC）** | **≈ 69.2 ms** | 需要补偿的总量 |

**这条直接验证了计划「不能无条件减 2112 samples」的告诫是对的。**
2112 samples @48 kHz = 44 ms；若按此硬减，会**过冲约 34 ms**（把 -69 ms 修成
+(-25) ms 仍然错，方向还反了）。真实的 AAC 净贡献只有 9.8 ms。

**⚠️ 结论订正：不得把 69 ms 写进产品代码。**（2026-08-07 复审后撤销）

上面这个数是**声学**测得的：click 经「输出设备 → 扬声器 → 空气 → 麦克风 → 输入
设备」这条链路，测得的 69 ms 里同时含有输出缓冲、扬声器延迟、声程、输入缓冲和
房间响应。换台机器、换副耳机、换个采样率，这个数就变了。**它只是本机这套设备
组合的观测值，推不出通用的固定补偿量。**

因此：

- **产品实现按共享 PTS 对齐**（门槛 2 已证明三路 PTS 同在 mach 时基），
  各路写入前统一 `pts - T0`，不做任何固定偏移。
- 69 ms 与 59 ms 这两个数**只作为「本机存在可观测的麦克风管线延迟」的证据**保留，
  不作为实现依据。
- 若将来真要补偿，必须走设备自报的延迟（如 `AVCaptureDevice` 的相关属性）
  或每次录制现测，不能用常量。

原始拆解数据仍然保留在下面，因为它证明了另一件有用的事：**AAC priming 只贡献
约 9.8 ms**，所以计划里「不能无条件减 2112 samples（44 ms）」的告诫是对的 ——
真按 2112 减会过冲。

附：LPCM 那次的容器起始值 —— mov 音轨 `start 0.028042`，`.caf` 无 start 偏移。

### 门槛 3 附带发现 1 — 音频**绝不能**在 `isReadyForMoreMediaData` 为假时丢弃

harness 初版按常见写法在 input 未就绪时 `return`（静默丢采样），实测后果：

```
请求录 6s：mov Duration = 17.95s，m4a Duration = 6.21s
麦克风写入 576 个采样，末 PTS 17.94s，但 m4a 内容只有 6.21s
```

**m4a 把丢掉的部分直接折叠掉了** —— 产物看起来起点正常、内容却整体提前，正是
计划 §20 预言的「m4a 折叠首尾空隙 → sidecar 看似同起点但内容提前」。

改为**有界 backlog**（未就绪则排队、下次补写，超限才显式计 partial）+ 收尾前
`flushBacklog()` 之后：

```
audio      : 到达 463  写入 463  溢出丢弃 0
microphone : 到达 863  写入 863  溢出丢弃 0
```

**产品实现必须照此办理**：音频排队不丢，溢出要显式变成 partial 并告知用户。
画面掉帧可接受但必须计数。

### 门槛 3 附带发现 2 — 录制期间必须持有活动断言，否则 App Nap 会拖垮时长

后台运行的 harness 请求录 6 秒，实际跑了 **17.95 秒**（411 个 screen 采样 ÷ 17.95s
≈ 23 fps，说明流真的跑了 18 秒），原因是 App Nap 节流了 `Task.sleep`。

加上 `ProcessInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled,
.latencyCritical])` 后，请求 8 秒 → T1 = 8.11 秒，正常。

**产品实现必须在录制期间持有同类断言。**

### 门槛 3 附带发现 3 — 约 4% 的 screen 采样没有 image buffer

`screen: 到达 219 写入 208`，差额既不是背压也不是早于 T0，而是
`CMSampleBufferGetImageBuffer` 返回 nil 的 idle/status 帧。这正是门槛 11
（完全静止画面只产生 idle frame）要处理的对象，产品需按 `SCFrameStatus` 分流。

### 门槛 11 — 静止画面的 idle frame 与 endSession → ⚠️ **结论 B 已于 2026-08-11 推翻：补尾帧是必需的**

静止画面录 10 秒，按 `SCStreamFrameInfo.status` 分类：

```
complete: 136 帧   其中无 image buffer 0
idle    : 109 帧   其中无 image buffer 109   ← 全部没有像素
到达 245，写入 136
```

**结论 A：`idle` 帧永远不带 image buffer**，占比可达 45%。它们是 SCK 在画面无变化
时的省带宽机制，**不是掉帧**，不能计入丢弃统计，也不能试图写入。

**结论 B（⚠️ 已于 2026-08-11 推翻，勿再引用）：~~`endSession(atSourceTime: T1)`
足以把时长延长到 T1，不需要补尾帧。~~**

```
共同 T1        = 10.460719s
文件 Duration  = 10.45s        ← 覆盖到 T1
```

**这次只量了「文件 Duration」，没有逐轨量 `AVAssetTrack.timeRange`。**
真相是：容器时长确实到了 T1，**画面轨却停在最后一次画面变化**——静止期
只有不带像素的 idle 帧，一帧都不写，而分片写入（`movieFragmentInterval`）
让最后那份采样的时长早已定死，`endSession` 改不动它。播放器会把最后一帧冻住，
所以从文件层面完全看不出来，进时间线合成才会暴露成**纯黑的尾巴**。

因此计划 §17.1 第 11 项的后备方案（补一份尾帧）**是必需的**，已实现为
`ScreenRecordingWriter.holdLastFrame(untilT1:)`。详见
[录屏静止期尾部黑屏](../bugfixes/2026-08-11-screen-recording-idle-tail-black.md)
与[录屏生命周期 · 产物合同](../architecture/screen-recording-lifecycle.md)。

**结论 C（影响 Phase 1 的工程帧率设计）：录制产物是变帧率的。**
配置 `minimumFrameInterval = 1/24`，但因 idle 帧不写入，实际平均只有
**12.93 fps**（136 帧 / 10.45 s）。`minimumFrameInterval` 是**上限**不是固定帧率。
工程帧率与录制帧数没有对应关系，导入时不能按帧数推时长，必须用容器时长。

### 门槛 9 — 按 window ID 排除控制窗 → ✅ **通过（像素级验证）**

harness 开一个纯洋红 borderless 窗口（`level = .floating`，主屏 60,60 260×160），
对照抓两帧，量窗口中心对应的捕获图像素：

```
控制窗 windowID=130766，在 SCShareableContent 中找到：是
采样点（捕获图坐标）= (190, 760)   显示器 1440x900

A 不排除任何窗口                                    → rgb(238, 61, 246)   洋红可见
B SCContentFilter(display:excludingWindows:[该窗])  → rgb(100,100,100)   洋红消失
```

**结论：`SCContentFilter(display:excludingWindows:)` 按 window ID 排除有效。**
产品「保留 SrtFlow 主界面、只排除录制控制 UI」的要求可以实现。

**附带发现（会影响所有像素断言）：捕获帧经过显示器色彩配置转换。**
窗口设的是纯洋红 `(255, 0, 255)`，捕获到的是 `(238, 61, 246)`。
本 gate 初版判定写了 `g < 60`，实测 g=61，**差 1 判成失败**。
产品与自检里任何比色都必须带容差，不能按精确值判定。

### 门槛 8 — 录到 SrtFlow 自己播放的声音 → ✅ **通过**

harness 用自己的 `AVAudioPlayer` 播放 click 轨，同时捕获系统声音，量 PCM 峰值：

```
excludesCurrentProcessAudio = false → 峰值 0.08840   采样 414720
excludesCurrentProcessAudio = true  → 峰值 0.00000   采样 389760
```

二值化得非常干净。产品要求「录制电脑声音，**包括 SrtFlow 自己播放的声音**」
只需 `excludesCurrentProcessAudio = false`。

### 门槛 13 — 崩溃后的 partial 可恢复性 → ✅ **已实测，得到一条硬性实现要求**

写一个持续产帧的 `.mov`，从外部 `kill -9` 打断，再用 `AVURLAsset` + `AVAssetReader`
检查产物（能否打开、有无轨道、时长、能否真解出帧）：

| `movieFragmentInterval` | 强杀于 | 文件大小 | 结果 |
| --- | --- | --- | --- |
| **不设置**（默认） | 4 s | 7250 字节 | **UNREADABLE** —— `AVFoundationErrorDomain code=-11829 Cannot Open` |
| **设为 1 秒** | 7 s | 14882 字节 | **RECOVERABLE** —— 轨道数 1、时长 7.0 s、成功解码 5 帧 |

**结论：产品必须设置 `writer.movieFragmentInterval`。** 不设的话 `moov` 只在
`finishWriting` 时写出，崩溃/强杀会让**整个文件打不开**（不是丢尾部，是全丢）。
设置后文件按片段自描述，时长反映最后一个完整片段。

这条是计划 §9.3「App 崩溃后的精确恢复」与 §16 partial 恢复矩阵能够成立的**前提**，
计划正文未点名该 API，属于实测补充。

### 门槛 4 — 长时累计漂移 → ✅ **10 分钟已实测通过**（30 分钟验证进行中）

**测法改进**：计划原文写的是「10 分钟和 30 分钟 click-track + 拍手测试」。改用
**纯数字对账**代替声学：每路音频累加 `CMSampleBufferGetNumSamples`，
把「采样帧数 ÷ 48000」与「首末 PTS 跨度」相比，差值即漂移。理由是它比声学测量
精确一个量级、不受环境噪声影响，且不需要连续 10 分钟播放提示音。
门槛 3 的绝对偏移仍用声学 click 测得（见上文），两者互补。

**10 分钟结果**：

```
audio     : 采样帧 28802880 → 600.060000s ；PTS 跨度 600.040000s ；差 +20.0 ms (+2.000 ms/分)
microphone: 采样帧 28800512 → 600.010667s ；PTS 跨度 600.000000s ；差 +10.7 ms (+1.067 ms/分)
零丢弃：audio 30003/30003，microphone 56251/56251
```

**30 分钟结果**：

```
audio     : 采样帧 86402880 → 1800.060000s ；PTS 跨度 1800.040000s ；差 +20.0 ms (+0.667 ms/分)
microphone: 采样帧 86401024 → 1800.021333s ；PTS 跨度 1800.010667s ；差 +10.7 ms (+0.356 ms/分)
零丢弃：audio 90003/90003，microphone 168752/168752
```

**结论：累积漂移为零。**

把两次并排看，结论比预想强得多：

| 时长 | audio 偏差 | microphone 偏差 | 两路相对差 |
| --- | --- | --- | --- |
| 10 分钟 | **+20.0 ms** | **+10.7 ms** | 9.3 ms |
| 30 分钟 | **+20.0 ms** | **+10.7 ms** | 9.3 ms |

**偏差量在 10 分钟和 30 分钟完全相同**，说明它根本不是累积漂移，而是恒定的**测量
边界效应**（首个 buffer 的采样计入总数、但其时长不计入首末 PTS 跨度）。折算成
「ms/分钟」会造成漂移的错觉 —— 时长翻三倍，速率就掉到 1/3，正是恒定量的特征。

因此：**两路音频之间不存在随时间累积的漂移**，相对差恒为 9.3 ms，与录制时长无关。
计划担心的「10/30 分钟累计漂移」不成立。

**结论：不存在随时长累积的漂移。**

⚠️ 注意这里**不能**顺势推出「用一个常量补偿 69 ms」——
69 ms 是**声学链路**的本机观测值（含输出缓冲、扬声器、声程、输入缓冲、房间响应），
换设备就变。产品按共享 PTS 对齐，不做固定偏移。详见门槛 3 的「结论订正」。

**backlog 设计在 30 分钟连续负载下零丢弃**，验证门槛 3 的修复可持续，非短录侥幸。

附：长录中 `idle` 帧占比 —— 10 分钟录制 62%（8643/5267，平均 8.8 fps），
30 分钟录制 35%（14786 idle / 26955 complete），随屏幕活动量变化，
进一步印证产物是变帧率的。

### 门槛 12 — 磁盘写满与 writer 状态 → ✅ **已实测，与门槛 13 共同确立一条数据安全底线**

用 `hdiutil` 造 12 MB 卷触发**真实 ENOSPC**（不是模拟）。首次尝试用纯色帧填充，
写了 574 秒才 1 MB —— H.264 把纯色压没了，测不出磁盘满；改用 `arc4random_buf`
随机噪声（不可压缩）后 18 秒即写满。

**ENOSPC 的精确识别特征**：

```
append 返回 false（第 435 帧）
writer.status = 3 (failed)
AVFoundationErrorDomain Code=-11807 "Disk Full"
  NSUnderlyingError = NSPOSIXErrorDomain Code=28 "No space left on device"
  NSLocalizedRecoverySuggestion = "Make room by deleting existing files and try again."
```

**两条检测路径都要查**：设了 `movieFragmentInterval` 时 `append` 先返回 false；
没设时 `writer.status` 先变 `.failed`。只查其中一个会漏。

**磁盘满后产物是否可恢复 —— 与 `movieFragmentInterval` 强相关**：

| 场景 | `movieFragmentInterval` | 文件大小 | 结果 |
| --- | --- | --- | --- |
| 磁盘写满 | **设为 1 秒** | 11,060,788 字节 | **RECOVERABLE** —— 1 轨道、18.0 s、成功解码 5 帧 |
| 磁盘写满 | **不设置** | 11,279,049 字节 | **UNREADABLE** —— `-11829 Cannot Open` |

**11 MB 已经落盘的数据，因为没有 `movieFragmentInterval` 而全部报废。**
这比门槛 13 的崩溃场景更常见（用户录一小时把盘写满是完全现实的），
两者共同确立同一条底线：**`movieFragmentInterval` 是数据安全的必要条件，不是优化项。**

### 门槛 14 — async `AVAssetExportSession` 的取消安全性 → ✅ **已实测，两条结论**

**结论 A：仓库现有的「启动必须在临界区内」约束在 macOS 26 上依然必要 —— 崩溃还在。**

复现 `docs/bugfixes/2026-08-05-export-prerender-review.md` 记录的完整危险序列
（对一条 `.unknown` 会话先 `cancelExport()` 再 `export()`）：

```
session.status（未起跑）= 0
cancelExport() 返回了，未崩溃。status=5
接着调用 export(to:as:) ——
libc++abi: terminating due to uncaught exception of type NSException
```

**进程直接终止，`do/catch` 拦不住**（我在 `export` 外层包了 catch，无效）。
注意只做前半段（单独 `cancelExport()`）**不会**崩，必须「取消后再启动」才复现 ——
这也解释了为何 `ExportCancellationToken.startSession` 必须把启动放进锁里。
**Phase 1 提升到 macOS 15 后不得放松这条约束。**

**结论 B：async `export(to:as:)` + 结构化 `Task.cancel()` 是安全干净的。**

```
立刻 task.cancel()（preset 强制重编码，避免 passthrough 太快测不出）
结果：抛 CancellationError
session.status = 5 (cancelled)
产物是否存在：false        ← 没有留下半成品文件
```

三点都正确：抛 `CancellationError`、状态是 cancelled、**不留残файл**。
录制功能可以放心用「async API + 结构化取消」，但**不能**因此改动现有预渲染的
原子启动写法（结论 A）。

<details><summary>过程中的两次自我纠正（留作方法论记录）</summary>

1. **枚举念错**：`AVAssetExportSession.Status` 是
   `unknown=0, waiting=1, exporting=2, completed=3, failed=4, cancelled=5`。
   我一度把 3 当成 cancelled，据此得出「返回成功但状态是取消」的错误结论。
2. **passthrough 太快**：H.264 源导出到 mp4 用 `AVAssetExportPresetHighestQuality`
   走的是重封装不重编码，4K/60s 素材也在 200 ms 内导完，取消根本没赶上。
   换成 `AVAssetExportPreset1280x720`（强制重编码）+ 立刻取消才测得出真实行为。

教训：**测「取消」必须先确认被测操作真的还在进行中**，否则测的是「完成后取消」。
</details>

### 门槛 7 — BGRA / 指针 / 点击效果 → ✅ **已实测**

在纯白背景窗中心放置指针，对比取帧：

```
showsCursor=false → 5x5 采样 25 点，非白（指针）像素 0 个
showsCursor=true  → 5x5 采样 25 点，非白（指针）像素 6 个
```

`showMouseClicks` 需要注入真实点击 + **连续收帧**才测得出：

```
单帧取样（初版）：false → 10/441 ；true → 10/441   ← 看不出差异，误判为不生效
连续 1.2s 取峰值：false → 10/441 ；true → 18/441   ← 生效
```

**结论：两个开关都生效**；但点击效果只闪现几百毫秒，**单帧取样必然错过**。
产品若要做相关自检，必须连续收帧取峰值。

BGRA 像素格式全程可用（本报告所有像素级判定都基于它）。
按计划要求，点击效果**只用系统 API 的结果**，未引入事件监听或自绘兜底。

### 门槛 10 — 多屏坐标 → ✅ **坐标系已确认**，另发现一条影响画质的关键事实

**结论 A：`SCDisplay.frame` 与 `CGDisplayBounds` 完全一致**，含负原点副屏：

```
displayID=1  frame=(0, 0, 1440, 900)          CGDisplayBounds 一致：true
displayID=2  frame=(-279, -1080, 1920, 1080)  CGDisplayBounds 一致：true
```

两者共用同一个「全局、左上原点」坐标系，负原点副屏无需特殊换算。

**结论 B（重量级）：`SCDisplay.width/height` 是「点」不是「像素」——
照它配置捕获会在所有 Retina 机器上录成半分辨率。**

```
NSScreen 1: frame 1440x900 点   backingScaleFactor 2.0  → 原生 2880x1800 像素
NSScreen 2: frame 1920x1080 点  backingScaleFactor 2.0  → 原生 3840x2160 像素

SCDisplay.width      = 1440   ← 点
CGDisplayPixelsWide  = 1440   ← **也是点**（名字极具误导性）
CGDisplayMode.width  = 1440   ← 点
CGDisplayMode.pixelWidth = 2880  ← 唯一返回真实像素的 API
```

**本报告此前所有测试录制都是 1440×900，而屏幕原生是 2880×1800 —— 即半分辨率。**
产品必须用 `CGDisplayMode.pixelWidth/pixelHeight`（或 `点 × backingScaleFactor`）
来设 `SCStreamConfiguration.width/height`，否则录出来是糊的。

**与门槛 6 联动的完整规则**：

1. 取原生像素尺寸 `pixelWidth × pixelHeight`；
2. 若任一边 > 4096，等比缩到两边都 ≤ 4096（否则掉出硬件编码器）；
3. 宽高取偶数。

本机两块屏原生 2880×1800 与 3840×2160 都在 4096 以内，可直接原生录制并硬件编码。

**尚未验证**：`sourceRect` 的像素网格精确命中。测试脚本的 NSWindow 定位换算有误
（把多屏全局坐标当成主屏坐标），标记窗没落在预期位置，命中 0/144。
这是**测试代码的坐标 bug，不是 API 结论**，需重写后复测。
「混合 Retina」子项本机无法覆盖 —— 两块屏 `backingScaleFactor` 均为 2.0。

见 §2：负原点副屏可测；混合 Retina 本机当前配置**不可测**，需人工改缩放。
像素网格实录本身待 harness。

### 门槛 5 — 麦克风设备（设备枚举部分）

```
Microsoft Teams Audio     uniqueID=MSLoopbackDriverDevice_UID
MacBook Pro Microphone    uniqueID=BuiltInMicrophoneDevice   [默认]
MJAudioRecorder           uniqueID=MJRecordDevice
```

本机有真实内建麦克风 + 两个虚拟设备，`AVCaptureDevice.default(for: .audio)` 有值。
可覆盖「明确 device ID」与「切换设备」；「无默认设备」需人工拔掉/禁用设备后复测。
**采集与 gap 行为待 harness，未验证。**

### 其余门槛（1–4、7–9、11–14）

**尚未验证。** 均需最小 `.app` harness + 真实 TCC 授权，见 §11 的阻塞项。

## 5. API 面编译探针（不能替代实测）

写了一个 typecheck 探针覆盖计划假设的 API：`SCContentSharingPicker` /
`SCContentSharingPickerConfiguration.excludedWindowIDs` / `allowedPickerModes`、
`SCContentFilter(display:excludingWindows:)`、`SCStreamConfiguration` 的
`sourceRect` / `capturesAudio` / `excludesCurrentProcessAudio` / `captureMicrophone` /
`microphoneCaptureDeviceID`、`stream.addStreamOutput(_:type:sampleHandlerQueue:)` 的
`.screen` / `.audio` / `.microphone`、`SCStream.synchronizationClock`、
`SCShareableContent.excludingDesktopWindows(_:onScreenWindowsOnly:)`。

```
swiftc -parse-as-library -target arm64-apple-macosx15.0 -typecheck sck-probe.swift
退出码=0
```

**全部存在且签名匹配。** 一处与文档命名直觉不符，记录备用：
`SCContentSharingPickerConfiguration.excludedWindowIDs` 的 Swift 类型是 **`[Int]`**，
不是 `[CGWindowID]`（`CGWindowID` 是 `UInt32`，需显式转换）。

> ⚠️ 这一节只证明**编译期**可用，按执行约束 3，**不构成任何门槛的通过证据**。

## 6. Phase 1–5 实施内容

### Phase 1：macOS 15 基线 + 工程帧率 —— **主体完成**

**1. 最低系统提升到 macOS 15**

- `Package.swift`：`.macOS(.v14)` → `.macOS("15.0")`。按计划用**字符串**而非 `.v15`
  —— PackageDescription 5.9 没有 `.v15` 枚举，用它会把包描述连带升到 tools 6.0。
  实测：tools 保持 5.9，构建通过。
- `packaging/Info.plist`：`LSMinimumSystemVersion` 14.0 → 15.0，并补齐三项用途说明
  （`NSScreenCaptureUsageDescription` / `NSAudioCaptureUsageDescription` /
  `NSMicrophoneUsageDescription`）。
- **两个自检脚本的 target triple**（计划 §3.1 点名的坑）：
  `scripts/check-project-file.sh` 与 `scripts/check-preview-composition.sh` 里的
  `arm64-apple-macosx14.0` → `15.0`。不改的话自检直接编译失败
  （`compiling for macOS 14.0, but module 'SrtFlowCore' has a minimum deployment
  target of macOS 15.0`）—— 实测撞到了。
- 文案：`scripts/build-app.sh` 内嵌的「首次打开必读」中英文、`README.md` 中英文
  运行要求、`SrtFlow-Requirements.md` 的最低系统行。

**2. 工程帧率 `ProjectFrameRate`（新文件 `Sources/SrtFlowCore/ProjectFrameRate.swift`）**

24 / 30 / 60，默认 24。放在 **SrtFlowCore** 而不是 App 层，这样 `SrtFlowCoreChecks`
能覆盖它；因此**不引入 CoreMedia**，只暴露 `frameDurationRational`，`CMTime` 的
构造留在 App 层。宽容解码：认不出的值回退 24（Int raw，仓库既有的
`LenientCodableEnum` 要求 String raw，故内联实现）。

**3. 接进 TimelineState 与工程格式 v5**

- `TimelineState.frameRate` 新字段，手写 Codable 的三处（CodingKeys / decode /
  encode）同步。
- **只有非默认帧率才落盘**，与 `subtitleCompanion` 同一取向：默认 24 的工程不写
  这个键，旧版读到的时间线与新版完全一致，不该被版本闸门关在门外。
- `requiresFormatVersion5` 加进 `VideoEditFormatVersion.swift` 的登记清单；
  `latestFormatVersion` 3→…→**5**，按需定版改成取所有登记项的最高要求。
- `selectionForExport` 补 `sub.frameRate = frameRate` —— 漏了这行选段导出会退回
  默认 24，与工程规格不符。

**4. 消费端接线**

- `VideoEditCompositionBuilder.buildVideoComposition` 的
  `frameDuration = CMTime(1, 30)` → 由工程帧率决定。
- **关键帧容差分空间**（计划 §17.2 明确要求，也是最容易写错的一处）：
  `KeyframeTrack.timeTolerance` 这个常量**删除**，改成显式传参，逼调用方想清楚
  自己在哪个空间：
  - source time 侧（`set` / `key` / `remove` / `allKeyTimes` / `merged` /
    合成切片边界 / 时间线菱形标记）用 `工程半帧 × |speed|`；
  - timeline time 侧（‹ › 跳帧，已先映射回 timeline）**只用工程半帧，不乘 speed**
    —— 乘了就是重复折算。
  历史值 `1.0/60` 恰好等于 30 fps 的半帧，所以 30 fps 工程行为完全不变。

**5. 自检扩展**

`checks/ProjectFile/main.swift` 新增 5 项帧率用例并修正版本断言：
默认 24 不抬版本 / 非默认抬到 v5 / 帧率存得住 / 改回默认降回 v3 /
旧工程缺键回退 24；reader 上限断言 v4→v5，拒开用例 v5→v6。

**验证（全部真实运行）**：

```
swift build --arch arm64                    → Build complete
swift run --arch arm64 SrtFlowCoreChecks    → All 290 checks passed
scripts/check-project-file.sh               → 92 checks, 0 failures（原 87，新增 5）
scripts/check-preview-composition.sh        → 13 checks, 0 failures
scripts/check-export-alpha-compositing.sh   → 0 处失败
```

**6. 导出管线与预渲染接线（本轮补完）**

- `VideoEditExporter` 的 **9 处** `fps=30` / `r=30` 全部改为 `fps=\(fps)`，
  `fps` 取自 `state.frameRate`（计划写的是 8 处，实测 9 处）。
- 新增扫描守卫 `checks/no-hardcoded-fps.sh`（计划 §17.3 要求）：扫 Video Edit
  管线里的 `fps=<数字>` / `:r=<数字>` / 写死的 `frameDuration` / 写死的
  `timeTolerance`，注释行豁免；**不管压缩管线**（`FFmpegArgumentBuilder` 的帧率
  是用户在编码设置里选的上限，与工程帧率无关）。
  **反向验证过**：故意塞回一处 `fps=30`，守卫准确报错并定位到行号。
- `VideoEditPrerender` 的三处临时 `TimelineState`（`renderMain` /
  `renderOverlay` 的 fill 与 matte）全部继承工程帧率 —— 预渲染产物要接回主图，
  帧率不一致接缝处对不上。
- **帧率选择 UI**：Edit Video 工具栏画布比例旁新增帧率菜单
  （`VideoEditView` + `VideoEditProject.setFrameRate`），走 `perform` 因此会触发
  预览重建（否则 `videoComposition` 还停在旧的 `frameDuration`）。

  **真机验证（已做）**：启动 App → File ▸ Edit Video → 工具栏出现「24 fps」菜单，
  展开为 `✓ 24 fps / 30 fps / 60 fps`（当前值带勾）；选中另一档后工具栏按钮
  确实变为「30 fps」。截图与辅助功能查询双重确认。

  **⚠️ 未验证：撤销。** 一次真机尝试中，改帧率后点 Edit ▸ Undo，工具栏仍显示
  30 fps 未回到 24。无法判定是菜单点击没落地、还是 `perform` 的撤销注册对该
  路径没生效 —— 后续 GUI 自动化不稳定（SwiftUI Menu 的键盘导航从当前项起跳、
  负原点副屏下 CGEvent 坐标点击不落地）。**在查清前不得宣称「帧率改动可撤销」。**
  待办：用真实鼠标手测，或改用更可靠的注入方式复验。

**7. 导出帧数自检（计划 §17.3）**

`checks/PreviewComposition/main.swift` 新增：2 秒素材在 24/30/60 三档下**真导出**
再数帧。过程中两次修正测法，都是真实发现：

1. **`AVAssetReaderVideoCompositionOutput` 数不出来** —— 直通合成（单段、无动画
   无转场）下它按**源帧**透传，`frameDuration` 不生效：10fps 的 2 秒素材在
   24/30/60 三档都只出 **20 帧**。改用真实 `AVAssetExportSession` 导出后才按
   `frameDuration` 重采样。
2. **三档都有 +2~3 帧的固定溢出**（AVFoundation 在指令边界补帧）：
   24fps 得 51 帧（理论 48）、30fps 得 62 帧（理论 60）。所以断言改成
   「帧数 ÷ 实际时长 ≈ 工程帧率，容差 10%」，而不是硬比帧数。
3. 另加一条**区分度断言**：三档的实测帧率必须明显递增
   （30 > 24×1.15、60 > 30×1.5）。理由是若哪天帧率又被写死，三档会得到**相同**
   帧数，只有百分比断言可能侥幸过关。

**8. Phase 1 收尾（2026-08-07 完成）**

- **导出 UI 不再给不存在的承诺**：`EncodeSettingsView` 加 `showsScalingLimits`
  开关，Video Edit 导出传 `false` 并改为明示「Output follows the project:
  W×H, N fps」。压缩与烧字幕仍显示这两个控件 —— 它们那边是真消费的。
- **用途说明本地化**：`packaging/Info.plist` 基准语言改英文（`defaultLocalization`
  是 en），新增 `en.lproj/InfoPlist.strings` 与 `zh-Hans.lproj/InfoPlist.strings`。
  已验证两份都进了 SwiftPM 资源包且 `plutil -p` 能解析。
- **alpha fixture 的 FPS 真参数化**并跑 24/30/60（此前那次替换因异常没落盘）。
- **新增真实生产导出回归** `scripts/check-export-frame-rate.sh`，见下。

**Phase 1 完成。**

### Phase 2：来源选择和 UI 骨架 —— **代码完成（含 UI），真机 picker 交互未验**

纯逻辑地基（均在 SrtFlowCore，可被自检覆盖）：

- `ScreenRecordingCoordinateMapper.swift` —— 多屏/Retina 坐标与尺寸换算纯函数。
  把 Phase 0 的两个陷阱固化成契约：捕获尺寸必须走**真实像素**、
  硬件编码**单边** ≤4096。翻转轴用**主屏高度**（曾误用屏幕并集顶边，见 §1 复审修正）。
  `displayLocalRect(fromAppKit:…)` 要求区域**完整落屏**，部分跨界返回 nil ——
  夹取是区域选择 UI 的职责，换算层不静默裁剪。
- `ScreenRecordingModels.swift` —— request / source / 麦克风配置 / 指针配置 /
  状态机 / 结果 / 错误 / manifest / 磁盘预算。

**未做**：`ScreenRecordingSourcePicker`（系统 picker adapter）、
`ScreenRecordingSetupView`、`ScreenRecordingRegionPanel`、
`ScreenRecordingControlPanel`、`ScreenRecordingCoordinator`、
`ScreenCaptureEngine`、`ScreenRecordingWriter`、
`VideoEditProject+ScreenRecording`。

### Phase 3：正式 capture + 主文件 —— **代码完成**

- `ScreenCaptureEngine.swift` —— SCStream 配置与三路 output 桥接。捕获尺寸用
  request 里**开录前冻结**的真实像素；`minimumFrameInterval` 取工程帧率（注意它是
  **上限**不是固定帧率）；`excludesCurrentProcessAudio = false` 以录到 SrtFlow
  自己的声音；`captureMicrophone` 传已解析的 uniqueID。
- `ScreenRecordingWriter.swift` —— 双 writer。Phase 0 的**七条**硬约束全部落实：
  必设 `movieFragmentInterval`、音频有界 backlog 绝不静默丢、三路 timescale 换算、
  **不做任何固定偏移**、共同 T0/T1、idle 帧不计掉帧、**画面轨自己盖到 T1**
  （第 7 条是 2026-08-11 补的：`holdLastFrame` 补尾帧 + 收尾后按**产物**
  复验画面轨 `timeRange.end`，短了判 partial）。ENOSPC 按
  `-11807` / `NSPOSIXErrorDomain 28` 双路径识别。
- `ScreenRecordingCoordinator.swift` + `+Setup.swift` —— 状态机、权限、
  倒计时、journal 提交（persist 成功才 rename）、低空间监测、崩溃恢复。
  **写盘期出错也走 stopping → finishing**，不直达 `.failed`。

### Phase 4：麦克风、入轨与退出 —— **代码完成**

- `VideoEditProject+ScreenRecording.swift` —— 一次 `perform` 完成计划 §10.2 的
  八条：主视频进主轨末尾、磁吸后**重读实际起点**、麦克风**始终新建一条轨**且
  起点对齐、同一 `linkGroup`、画布四条件全成立才自动设、选中并移播放头。
- 新增 `VideoEditProject.canvasEditGeneration` —— 只比对比例值挡不住
  「改了又改回」，值和代号都没变才算数。
- 工程切换锁挂在 `prepareToCloseDocument()`（New/Open/Open Recent/Finder 打开/
  退出的**必经之路**），不是按钮 disabled。
- `applicationShouldTerminate` 走 `.terminateLater`，由 coordinator
  **唯一一次** reply（`finishTerminationWait` 幂等，反复按 Quit 安全）。
- 帧率在录制期间冻结（菜单置灰 + `setFrameRate` 执行入口二道闸）。

### Phase 5：全量验证 —— **部分完成**

见 §9 与 §10。自动化部分全绿；真机矩阵未跑。

## 7. 关键架构实现说明

长期约束已全部沉淀到
[docs/architecture/screen-recording-lifecycle.md](../architecture/screen-recording-lifecycle.md)
（状态机、提交 journal、清账合同、文件覆盖与命名、退出协调、自检纪律）与
[docs/architecture/project-frame-rate.md](../architecture/project-frame-rate.md)。
四轮复审的完整问题清单与修法见
[docs/bugfixes/2026-08-07-screen-recording-phase2-4-review.md](../bugfixes/2026-08-07-screen-recording-phase2-4-review.md)。
本节不重复，只列出实现上最容易改坏的三条：

1. **journal 的「意向」必须包含最终目标路径。** 只落 stage、把避让后的目标留到
   rename 时才决定，等于没落意向（复审二 P1-3）。
2. **阶段语义不可复用。** 纯麦克风恢复有独立的
   `microphoneOnlyCommitting/Committed`；复用 `committingMicrophone` 会让
   `mainResolution` 无条件认定主文件已提交，把用户原有的文件认成本次录屏
   （复审四 P1-1）。
3. **可选通道的失败不得写进共用失败态。** 麦克风的 writer、stream output、
   设备 ID 失败一律降级，主画面与电脑声音继续（计划 §1；复审三 P1-4、复审四 P1-2）。

## 8. 修改文件

### 新增

| 文件 | 职责 |
| --- | --- |
| `Sources/SrtFlowCore/ProjectFrameRate.swift` | 工程帧率（24/30/60，默认 24），纯逻辑 |
| `Sources/SrtFlowCore/ScreenRecordingCoordinateMapper.swift` | 多屏/Retina 坐标与尺寸换算纯函数 |
| `Sources/SrtFlowCore/ScreenRecordingModels.swift` | 录屏值类型：request/来源/麦克风/指针/状态机/结果/错误/manifest/磁盘预算 |
| `Sources/SrtFlow/VideoEditExportGraph.swift` | 从 `VideoEditExporter.swift` 拆出（908 行超警戒线），也让生产滤镜可被独立回归 |
| `Sources/SrtFlowCoreChecks/ScreenRecordingChecks.swift` | 上述三个 Core 文件的自检（顶层脚本塞不下，见 §1 修正 6） |
| `Sources/SrtFlow/Resources/{en,zh-Hans}.lproj/InfoPlist.strings` | 三项权限用途说明的本地化 |
| `checks/ExportFrameRate/main.swift` + `scripts/check-export-frame-rate.sh` | **真实生产导出滤镜**的帧率回归 |
| `checks/no-hardcoded-fps.sh` | 扫描守卫：不许写死帧率 |
| `docs/reports/…implementation-report.md` | 本报告 |
| `docs/bugfixes/2026-08-07-screen-recording-foundation-review.md` | 本轮复审抓出的假绿与真 bug |
| `Sources/SrtFlow/ScreenRecordingPermissions.swift` | 权限查询门面（含 -3801 文案约束）+ MediaProbe 窄封装 |
| `Sources/SrtFlow/ScreenRecordingSourcePicker.swift` | 系统 picker adapter |
| `Sources/SrtFlow/ScreenRecordingControlPanel.swift` | Stop 浮窗（提供 windowID 供排除）|
| `Sources/SrtFlow/ScreenRecordingRegionPanel.swift` | 区域选择 overlay |
| `Sources/SrtFlow/ScreenRecordingSetupView.swift` | 设置页 + partial/恢复处置弹窗 |
| `Sources/SrtFlow/ScreenCaptureEngine.swift` | SCStream 与三路 output 桥 |
| `Sources/SrtFlow/ScreenRecordingWriter.swift` | 双 writer（Phase 0 七条硬约束，第 7 条含产物轨道复验）|
| `Sources/SrtFlow/ScreenRecordingCoordinator.swift` + `+Setup.swift` | 状态机 / journal / 恢复 / 退出协调 |
| `Sources/SrtFlow/VideoEditProject+ScreenRecording.swift` | 单事务入轨 |
| `docs/architecture/screen-recording-lifecycle.md` | 生命周期长期约束 |

### 修改

| 分组 | 文件 |
| --- | --- |
| 构建基线 | `Package.swift`、`packaging/Info.plist`、`scripts/build-app.sh`、`scripts/check-project-file.sh`、`scripts/check-preview-composition.sh` |
| 工程模型与格式 | `VideoEditModels.swift`、`VideoEditFormatVersion.swift`、`VideoEditProjectFile.swift` |
| 帧率消费端 | `VideoEditCompositionBuilder.swift`、`VideoEditExporter.swift`、`VideoEditPrerender.swift`、`VideoEditAnimation.swift`、`VideoEditProject+Keyframes.swift`、`VideoEditProject+Transform.swift`、`VideoEditTimelineView.swift` |
| UI | `VideoEditView.swift`（帧率菜单）、`VideoEditProject.swift`（`setFrameRate`）、`EncodeSettingsView.swift`（`showsScalingLimits`） |
| 自检 | `checks/ProjectFile/main.swift`、`checks/PreviewComposition/main.swift`、`scripts/check-export-alpha-compositing.sh`、`Sources/SrtFlowCoreChecks/main.swift` |
| 文档 | `AGENTS.md`、`README.md`、`SrtFlow-Requirements.md` |

## 9. 构建与测试命令及真实结果

全部为 2026-08-07 本轮实跑：

| 命令 | 结果 |
| --- | --- |
| `swift build --arch arm64` | Build complete |
| `swift run --arch arm64 SrtFlowCoreChecks` | **All 502 checks passed**（基线 290；含状态机可达性、manifest 崩溃切点与卷不可达矩阵、ManifestStore 落盘栅栏、request 不可变契约） |
| `scripts/check-project-file.sh` | **97 checks, 0 failures**（基线 87） |
| `scripts/check-preview-composition.sh` | **24 checks, 0 failures**（基线 13） |
| `scripts/check-export-alpha-compositing.sh` | 24/30/60 三档，0 处失败 |
| `scripts/check-export-frame-rate.sh` | **19 checks, 0 failures**；实测 24fps→48 帧、30fps→60 帧、60fps→120 帧 |
| `checks/no-hardcoded-fps.sh` | 通过（文件系统枚举，含未跟踪文件；规则含 `minimumFrameInterval` / `AVVideoExpectedSourceFrameRateKey`） |
| `git diff --check` | 干净 |

**反向验证**（证明检查真的能失败，不是摆设）：

| 守卫 | 注入的错误 | 结果 |
| --- | --- | --- |
| `no-hardcoded-fps.sh` | 在生产滤镜里塞回 `fps=30` | 报错并定位到行号 |
| `no-hardcoded-fps.sh` | 在**未跟踪**的 `ProjectFrameRate.swift` 里塞 `fps=30` | 报错（改用文件系统枚举后才抓得到） |
| `check-export-frame-rate.sh` | 把 `let fps = state.frameRate.fps` 改成写死 30 | **六条断言同时失败**（参数缺失、混入错值、帧数不符） |

## 10. 验证性质分级

| 分级 | 内容 |
| --- | --- |
| **已自动验证** | Phase 0 的门槛 2/3/4/6/7/8/9/11/12/13/14（真跑 harness、真录、真解码 PCM、真触发 ENOSPC、真强杀）；Phase 1 的全部改动（460+97+24+19 项自检 + 两条扫描守卫 + 三条反向验证）；Phase 2 纯逻辑地基 |
| **已人工验证** | Phase 0 的屏幕录制 TCC 授权（用户手动在系统设置里开启）；Phase 1 的帧率菜单真机操作；**Phase 2 的 UI 冒烟**（真机启动 → Record Screen 入口在工具栏 → 设置页完整渲染：Source/Audio/Pointer/Output「24 fps · follows the project」，截图确认）；**设置页与状态的绑定**（点 Close → 状态回 `.idle` → 页自动关且工具栏按钮恢复可用，AX 探针读取 enabled 确认）；**`.choosingSource` 期间 Quit 不再死锁且经过文档保存关**（插桩三行 DIAG 实跑）；**崩溃恢复三条路径**（mic 临时文件不被误删 / 「Keep file only」真的提交而非删除 / 「Add to timeline」把麦克风建成独立音频轨），均为植入账本后 AX 驱动实跑并截图 |
| **尚未验证（重要）** | **一次真实的端到端录制从未跑过**（需要人点 picker / 授权）。具体：门槛 1 的三条来源 picker 交互；四轮共 27 个 P1 里，实机验到的是退出死锁、恢复锁工程/回 idle、mic 临时文件不被误删、「Keep file only」真提交、麦克风独立轨入轨；其余仅有代码与纯逻辑自检；采样队列栅栏 / `stopHostTime` 定 T1 / 单调 PTS 都要真实 `SCStream` 才能验；控制窗排除失败路径、同尺寸双屏歧义、sidecar 避让、崩溃恢复三选一均未实机走过；门槛 5 的「无默认麦克风设备」；门槛 10 的混合 Retina 与 `sourceRect` 像素网格实录；帧率改动的撤销；计划 §17.4 的全部 GUI/TCC 矩阵（三条来源 × 多屏 × 音频开关 × 空间/中断/睡眠 × 强杀恢复 × 录制中 Quit）；长时真机录制 |

## 10.5 真机验收（2026-08-08，用户实测）

| 场景 | 结果 |
| --- | --- |
| 整屏录制（picker → 保存位置 → 倒计时 → Stop → 入轨）| ✅ 8.4 s / 2880×1800 真实像素 / 片段带缩略图进主轨 |
| 麦克风 | ✅ 独立音频轨 `…-Mic`，与主轨起点对齐、波形正常 |
| 自定义区域 | ✅ 默认框 / 八把手缩放 / Cancel·Record 按钮 / 录制期浅遮罩且遮罩未被录进成片 |
| Stop 浮窗排除 | ✅ 未出现在成片中（`NSWindow.sharingType = .none`）|
| 保存位置 | ✅ 预填 `~/Downloads` + 建议文件名，改过一次后记住目录 |
| 倒计时 | ✅ 浮窗显示 3 / 2 / 1 + "Starting…" |

**这一轮真机暴露、且自动化自检当时完全没抓到的 5 个问题**（详见
[案例](../bugfixes/2026-08-07-screen-recording-phase2-4-review.md)第五轮）：

1. 状态机缺 `.choosingSource → .choosingDestination` 一条边 →
   `transition` 静默返回 false → **录制永远不会开始**。
2. 音频覆盖容差取「一个工程帧」→ AAC priming(44 ms) 必然超标 → 每次录制都误报
   partial（违反了计划 §8.3 自己写的禁令）。
3. 控制窗排除依赖 `SCShareableContent`（需广域授权），而 picker 路径的意义
   恰恰是不要广域授权 → 改用 `sharingType = .none`。
4. notice 横幅 `lineLimit(1)` 把权限指引截成半句，等于没报。
5. 保存位置在系统 picker **之后**才问，用户被连问两次、不知走到哪一步。

## 11. 未完成项、已知风险与阻塞

### 阻塞（需要人工介入）

1. ~~TCC 屏幕录制授权~~ → **已完成**（2026-08-06）：最终生效路径是
   `tccutil reset` + 用户在系统设置里把开关关掉再打开；「Allow」弹窗自始至终
   没有出现过（此现象已记入门槛 1 结论）。harness 采用「稳定启动器 + 可变
   payload」结构后，重编代码不再使授权失效。
   注意：不能移动或重签 `~/Desktop/SrtFlowCaptureHarness.app`，否则 TCC 失配。
1b. **ad-hoc 签名导致 TCC 卡死** —— 需在 Phase 2 用真实 SrtFlow 复验它对正式分发
   的影响（正式包同样是 ad-hoc 签名）。
2. **混合 Retina 用例** —— 本机两屏 scale 均为 2.00，需人工把外接 LG 4K 改成
   非 2x 缩放档才能覆盖门槛 10 的该子项。
3. **无默认麦克风设备用例** —— 需人工禁用/拔除所有输入设备。

### 已知风险

1. ~~门槛 6 的真实上限待实测~~ → **已定案**：M1 硬件 H.264 编码器**单边 ≤ 4096**
   （与总像素无关），超限静默掉软件编码。规则已固化进
   `ScreenRecordingCoordinateMapper.fitToHardwareEncoder` 并有自检。
2. 计划 §3.3 的「8 组滤镜」实为 9 处，改帧率时扫描守卫要按 9 处核对。

## 12. 与原计划的偏差

| 偏差 | 原因 |
| --- | --- |
| §20「`canApply` 预检」不可用 | 实测对 8K 亦返回 true（只校验设置字典形状）。**替代方案已定案**：硬件 H.264 单边 ≤ 4096（与总像素无关），由 `ScreenRecordingCoordinateMapper.fitToHardwareEncoder` 实施，有自检；不改变产品范围。计划 §7.1 与风险表已回填 |
| §3.3「8 组生产滤镜」→ 9 处 | 实际计数 |
| §9.2「manifest 写入 UserDefaults」→ `ScreenRecordingManifestStore` | `UserDefaults.set` 内存立即生效、磁盘异步写入，当不了 journal 栅栏。改单 JSON 文件原子写；计划 §9.2 / §16 / §20 已回填 |
| 清 manifest 的判据从「文件现场」→ `ScreenRecordingRecoveryLedger.canClearManifest` | 现场（`FileResolution`）无法表达「用户还没决定」「入轨事务未提交」，仅凭它清账会留下孤儿文件 |

## 13. 发现并修复的 bug

见 §8「修改文件」与 `docs/bugfixes/2026-08-07-screen-recording-foundation-review.md`
（本轮复审抓出的假绿与真 bug）。

## 14. 最终 git status 与 diff 概览

起点：`731e5c3`（工作区 clean）。当前工作树为 Phase 1–2 的全部实现与配套
文档，未 commit（按执行约束 9）。改动全景见 §8「修改文件」；构建与自检结果
见 §9。`git diff --check` 干净。
