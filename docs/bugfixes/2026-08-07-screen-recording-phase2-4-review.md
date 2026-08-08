# 录屏 Phase 2–4 复审：8 个 P1 与它们的共同病根

> 2026-08-07。外部复审在 Phase 0–4 代码完成、全部自检通过之后，读代码找出
> 8 个 P1。**当时的绿是真的**（build + 555 项 + 5 个脚本），但它们全都只覆盖
> 纯逻辑；这 8 个问题一个都不在纯逻辑里。
>
> 前一轮的四次复审记在
> [2026-08-07-screen-recording-foundation-review.md](2026-08-07-screen-recording-foundation-review.md)。

## 共同病根

八个问题分属四类，都不是「算错了」，而是**契约在跨层传递时断掉**：

| 病根 | 表现 | 涉及 |
|---|---|---|
| 纯函数写对了，生产代码没用它 | `canClearManifest` / `displayLocalRect` 一个没被调用，一个拿错坐标系 | P1-3、P1-6 |
| 顺序错位 | 先提交后验证、先 reply 后问文档、picker 前抢读 `SCShareableContent` | P1-2、P1-1、P1-5 |
| 状态机只覆盖了「正常路径」 | 配置期的 Quit 落进 `default:` 静默返回 | P1-1 |
| 「报错」写到了看不见的地方 | 设置页先 dismiss，错误只写在页内 | P1-7 |

**教训：自检覆盖的是"函数算得对不对"，不是"这个函数有没有被调用、调用时参数
对不对"。** 纯函数越漂亮，越容易让人以为接线也是对的。

---

## P1-1 退出：既可能丢工程，也可能永久卡死

两个独立缺陷叠在同一条路径上。

**(a) 卡死。** `stop()` 的 `switch` 只处理 `.recording / .starting / .countingDown`，
配置期（`.configuring` / `.choosingSource` / `.choosingDestination` / `.preparing`）
落进 `default: return`。而 `prepareToTerminate()` 已经返回 false 让 AppKit 进入
`.terminateLater` —— 那个 reply 永远不会来，App 退不掉，只能强杀。

**(b) 丢工程。** 收尾完成后 `releaseResources()` 里直接
`finishTerminationWait(shouldTerminate: true)`，**完全跳过
`VideoEditProject.prepareToCloseDocument()`**。录制刚入轨就按 ⌘Q，未命名工程
不会询问保存；已有工程的自动保存有 2 秒防抖，也可能来不及落盘。

**修法**

- `prepareToTerminate()` 按状态分三档：终态直接放行；配置期
  `invalidateSession()` 撤销会话后放行；写盘期才 `.terminateLater`。
- `releaseResources()` **不再 reply**。收口改到 `settleTerminationIfPossible()`，
  它在 `transition()` 里每次落到非忙状态时被调用，并且
  **`shouldTerminate` 取自 `prepareToCloseDocument()` 的返回值**。
- `applicationShouldTerminate` 里，`prepareToTerminate()` 返回 true 时
  **继续往下走文档那一关**，不能直接 `.terminateNow`。

**实机验证**（插桩后真跑，`.choosingSource` 状态下按 Quit）：

```
DIAG shouldTerminate isBusy=true state=choosingSource   ← 旧代码在此永久挂起
DIAG after prepare state=idle                            ← invalidateSession 生效
DIAG prepareToCloseDocument=true                         ← 旧代码完全跳过这一关
已退出
```

### 顺带发现（既有问题，非本次引入）

**任何 sheet 开着时，`applicationShouldTerminate` 根本不会被调用**，⌘Q 毫无反应。
用与录屏无关的 Export sheet 做对照，行为一致，所以这是本 app 所有 sheet 的
既有行为，不在本轮范围内。好在它不是死锁 —— App 只是拒绝退出，不是挂起。

### 附带修正：设置页的两份真相

设置页原先由 `VideoEditView` 的 `@State showsRecordingSetup` 驱动，与 coordinator
状态各说各话 —— 会话被撤销了页还开着。改成
`state == .configuring` 的投影后，Close / 撤销 / 失败都会自动关页。

**注意**：这条改动要求把 `startRecording()` 里的 `dismiss()` 删掉。留着的话
`dismiss()` 会先把状态打回 `.idle`，`start()` 的入口 guard 随即失败，录制根本
起不来。

---

## P1-2 无效文件先覆盖了用户的目标文件

原顺序是 `commitFiles()` → `probe(最终路径)`。于是一个**损坏或零帧的临时文件**
会先 rename 到用户在 Save 面板选的位置，把那里原有的文件覆盖掉，之后才发现
它不能用 —— 用户既没拿到录制，又丢了旧文件。

更隐蔽的是 `commitFiles` 在临时文件不存在时**仍推进到 `.mainCommitted`**。
若最终路径上原本就有文件，后续 probe 读到的是**用户的旧文件**，会被当成本次
录制导入时间线。

还有麦克风 sidecar：路径是主文件同名加 `-Mic.m4a`，开录前没做冲突检查，
上一次录制的 sidecar 会被静默替换 —— 而用户只在 Save 面板里确认过**主文件**
的覆盖，从没同意过 sidecar 的。

**修法**

- **先验证后提交**：probe 的对象改成**临时文件**，通过了才 `commitFiles()`。
  判定无效就地删除临时文件（我们自己的精确路径，安全），绝不碰最终路径。
- 临时文件不存在时 `commitFiles` **抛错**，不再带着"已提交"的 stage 往下走。
- 新增 `ScreenRecordingFileNaming.availableURL(like:isTaken:)`：sidecar 在开录前
  避让到 `-Mic 2.m4a`、`-Mic 3.m4a`… 的第一个空位，提交时再避让一次兜住竞态。
  `isTaken` 注入使它可被反证。
- `commitFiles` 返回 sidecar 的**实际**最终路径，结果里用它而不是请求里的原始值。

---

## P1-3 崩溃恢复会丢文件，「保留」按钮实际执行删除

**最严重的一条：`resolveRecovery(import: false)` 删除文件，而按钮写的是
"Keep file only"。** 这是直接的数据丢失，用户以为自己在保留。

其余四处：

- `recoverIfNeeded` 计算了 `micResolution` 却**只按 main 分支**。
  `mainCommitted` + mic 临时文件还在时，走「清理 pendingTemporaryPaths」把一份
  **可以恢复的**麦克风录音删掉。
- `allCommitted` 但还没入轨就崩了，直接清账，用户再也收不到「有一段录制没进
  时间线」的提示。
- 损坏的 manifest 被静默删除，与架构文档「保留并如实报告」的要求冲突。
- 上一轮专门为此建的 `ScreenRecordingRecoveryLedger.canClearManifest`
  **生产代码一次都没调用过**。

**修法**

- 恢复弹窗改成**三选一**：Discard / Keep file only / Add to timeline。
  删除只在 Discard 时发生。
- 动作裁决抽成纯函数 `ScreenRecordingRecoveryPlan.make(manifest:两路观察)`
  → `waitForVolume / offerSalvage / offerImport / reportMissing / discardTemporaries`。
  **两路都看**，任一路卷不可达就整体等待。
- 清账的唯一入口 `clearManifest(plan:disposition:)`，判据是 ledger。
  入轨失败传 `.importPending` → 不清账，下次启动继续提示。
- 「保留」时把临时文件**提交到用户当初选的位置**（隐藏的 `.partial` 文件对
  用户没有意义），最终路径已有文件则避让，不覆盖。
- 损坏 manifest：保留 + notice 如实报告。

新增 11 条断言覆盖上述每一格，三条做了反证（把 bug 改回去确认能抓到）。

---

## P1-4 Writer 的停止合同没落地

- **没有采样队列栅栏。** `stopCapture()` 返回不代表回调都跑完了，writer 可能
  一边 `append`，主线程一边 `markAsFinished` / `finishWriting`。
- **`.started` 被当 idle 丢了。** 它是系统定义的第一帧，带 image buffer。
- **idle 帧的时间戳完全不记。** T1 取自最后一个非 idle 采样，于是
  「静止画面 + 关闭电脑声音」会得到 0 秒、或只到最后一次画面变化的文件。
- finalize 后只检查主 writer，**麦克风 writer 失败会被当成功** —— 用户以为
  录到了旁白。
- 没有拒绝重复或倒退的 PTS（AVAssetWriter 遇到会直接判 failed，丢掉整段尾巴）。

**修法**

- `stop()` 里 `stopCapture()` 之后在串行采样队列上排一个空块当栅栏；
  writer 侧另加 `isFinishing` 标志拒收并计数（`afterFinishDrops`，正常为 0）。
- `frameStatus` 把 `.complete` 与 `.started` 都算真帧；engine 侧判据取
  「状态说 idle」**或**「确实没有 image buffer」，状态读不出来时不误伤真帧。
- 新增 `observedEnd`：**含 idle 帧**的最大相对时刻，供 `elapsed` 与 T1 使用。
- `finish(stopHostTime:)` 接收 engine 在 stop 那一刻读的 host clock
  （三路 PTS 与 host clock 共享 mach 时基，Phase 0 门槛 2 已实测），取上界。
- 单调性检查 + `nonMonotonicDrops` 计数；mic writer 状态并入 partialReason。

---

## P1-5 clean TCC 下 picker 路径首跑即失败

`chooseSource` 在弹 picker **之前**调 `refreshDisplays()`，后者提前读
`SCShareableContent`。未授权时它失败并留下**空缓存**，于是用户在 picker 里
选好了窗口，回调却反推不出来源 —— 首次运行直接废掉。

另两处：

- 已授权时几何匹配只比较宽高且取 `first`，**两块同尺寸显示器会取第一块**，
  用户选了右屏却录了左屏，录完才发现。
- 控制窗没在 `SCShareableContent` 里找到时**没有失败保护**，带着空排除集继续录，
  Stop 浮窗会永久糊在成片里。

**修法**

- 来源解析全部挪到 picker 回调**之后**（此时用户已在 picker 里授权，读取安全）。
- macOS 15.2+ 直接用 `filter.includedDisplays` / `includedWindows`；
  15.0/15.1 退回几何匹配，但**要求唯一**，多于一个候选就抛 `.ambiguousSource`。
  **宁可报错也不猜** —— 猜错就是录错屏。
- 控制窗查找加重试（窗口刚 `show()` 可能还没进 window server 列表），
  始终找不到就抛 `.controlWindowUnavailable`，不带空排除集开录。

---

## P1-6 多屏坐标与窗口分辨率接错线

- `ScreenRecordingRegionPanel.confirm()` 返回的是**全局 CG 坐标**，而
  `SCStreamConfiguration.sourceRect` 要的是 **display-local**。
  主屏碰巧原点为零，看不出来；副屏会整体偏移甚至越界。
  上一轮写好的 `displayLocalRect` 就在那里，没被调用。
- 单窗口来源固定用**主屏 scale** 推算像素尺寸，窗口在副屏（尤其 Retina 与
  非 Retina 混插）时分辨率是错的。

**修法**：区域面板改调 `displayLocalRect`（不完整落屏则不确认，让用户重拉）；
窗口尺寸改用 `pickerFilter.contentRect × pointPixelScale`。

---

## P1-7 错误对用户实际不可见

设置页在调 coordinator **之前**就 dismiss 了，而 `errorMessage` 只显示在该页
里面。于是 picker、权限、目标位置、writer 的失败在用户眼里就是
**「点了没反应」**。麦克风被拒同理。

另外 `handleSetupFailure` 用的是 `(error as? LocalizedError)?.errorDescription`，
而 `ScreenRecordingError` **没有实现 `LocalizedError`** —— 精心写的权限文案
（含「开关已经开着就关掉再打开」）会退化成通用错误码。

**修法**：新增 `report(_:)`，同时写 `errorMessage` 和
`VideoEditProject.shared.notice`（横幅与设置页无关，一定看得见）；
失败路径一律先试 `ScreenRecordingError.localizedText`。

---

## P1-8 两个事务所有权漏洞

- `self.writer` 在 `writer.start()` **成功之后**才赋值。主 writer 已建好文件、
  mic writer 启动失败时，清理路径上的 `writer?.cancel()` 是 nil，
  两个临时文件泄漏，而 manifest 已经被清掉 —— 再也没人认领它们。
  **修法：先登记所有权再 `start()`。**
- `importScreenRecording` 可以提前返回失败（probe 读不出、工程身份变了），
  但 coordinator **无条件清 manifest 并标记 finished**。文件已经是用户的了，
  却既没进时间线、也不会再被提示。
  **修法：返回 `Bool`，失败时保留 manifest 并在消息里告诉用户文件存在哪。**
- mic probe 失败会静默少一条轨。**修法：明确 notice 告知。**

---

## 这一轮补的测试

新增 21 条断言（555 = 534 + 21），集中在两个纯函数上：

- `ScreenRecordingRecoveryPlan.make` 的 stage × 两路观察矩阵，
  **复审点名的三个反例逐条落成断言**。
- `ScreenRecordingFileNaming` / `availableMicrophoneURL` 的避让规则。

三条反证（把 bug 改回去，确认断言真的会红）：

| 反证 | 结果 |
|---|---|
| 恢复只看主文件裁决 | `FAIL … got offerImport, expected offerSalvage` |
| `allCommitted` 直接清账 | `FAIL … got discardTemporaries([]), expected offerImport` |
| 文件命名退回覆盖 | 4 条 FAIL |

**仍然测不到的**：三路 PTS/栅栏/T1 需要真实 `SCStream`；picker 交互、
控制窗排除、多屏区域需要人点。这些如实留在报告的「尚未验证」里。

---

---

# 第二轮复审：8 个 P1 + 3 个 P2（同日）

上面那批修完之后，复审再读一遍生产链路，又找出 8 个**静态可确定**的 P1 ——
全都不需要等实机录制就能判定。这一轮的病根更集中：**上一轮修的是「函数
写对没有」，这一轮暴露的是「跨模块的契约有没有真的对上」。**

## P1-1 麦克风轨此前必然无法导入

`ScreenRecordingProbe.info()` 底下是 `MediaProbe`，而它
**无视频轨就抛 `noVideoTrack`**（`MediaProbe.probeWithAVFoundation`）。
用它探纯音频 sidecar 永远返回 nil，于是 `micDuration` 恒为 nil，
**麦克风轨永远进不了时间线**。即使修好 probe，建出来的 clip 也漏了
`isAudioOnly: true` 与 `audioAssetDuration`（对照既有的
`VideoEditProject.addAudio` 才发现）。恢复导入更是**完全忽略**
`result.microphoneURL`。

修法：新增 `ScreenRecordingProbe.audioDuration(_:)` 按音频轨自己判；
两条导入路径都补齐 `isAudioOnly` / `audioAssetDuration`；
`importRecoveredRecording` 补上麦克风轨。

**实机验证**：植入 `allCommitted` 账本 → 启动 → 点「Add to timeline」，
时间线出现主轨 `Rec` + 独立音频轨 `Rec-Mic`，起点对齐（截图确认）。

## P1-2 自检覆盖到的那一格，生产代码照样删文件

自检正确产出 `offerSalvage(main: nil, mic: temp)`，但生产代码把
`mainTemp` 的 nil **回退到 `manifest.mainTemporaryPath`** ——
那是一个主文件已提交后**根本不存在**的路径。probe 必然失败，于是走进
「救不回来」分支，把那份**完好的麦克风录音删掉并清账**。

> 上一轮刚写完「自检覆盖的是函数算得对不对，不是有没有被正确使用」，
> 这一轮就在同一个功能点上再犯一次：**断言产出了正确答案，消费端把它用错了。**

修法：两路各自独立判定，`mainTemp == nil` 时改用 `mainFinalPath`（若已提交）；
两路都救不回来才删；`commitRecovered` 只提交**实际存在**的临时文件。

**实机验证**：植入「main 已提交 + mic 临时文件在」的账本 → 启动 →
mic 临时文件仍在、manifest 保留、恢复框弹出（旧代码此时已把文件删了）。

## P1-3 文件名二次避让破坏 journal 身份

正常提交与恢复提交都是**先持久化 `committing` 意向、再挑避让后的名字**。
rename 之后、stage 更新之前崩溃时，manifest 记的是旧路径、文件却在新路径：
要么产生无人认领的孤儿文件，要么把恰好占着旧路径的**无关文件**认成本次 sidecar。

修法：新增 `retargetingMicrophone(to:)` / `retargetingMain(to:)`
（构造新值，四条路径仍是 `let`），**最终目标先写进 manifest 再持久化意向，
然后才动文件**。

## P1-4 commit 失败仍直接清账

`commitFiles()` 任一步抛错都落到默认的 `finishWithFailure(clearManifest: true)`。
主文件已提交、mic move 失败时 manifest 被清除，那份仍然有效的隐藏 mic 临时文件
**永久失去认领**。也说明「ledger 是唯一清账入口」的生产契约当时并未成立。

修法：提交失败一律 `clearManifest: false`。

## P1-5 启动恢复会误处理**正在录制的当前会话**

`recoverIfNeeded()` 挂在 `VideoEditView.task` 上，而那个 task 在
「切到别的工具再切回 Edit Video」时会重跑。录制进行中切回来，它会读到
**当前正在写的 manifest**，可能 probe、提示、甚至删掉当前临时文件。
另外 `begin()` 不检查未结清的 manifest，新录制会**覆盖唯一的那份账**。

修法：`hasAttemptedRecovery` 一次性闸 + `state == .idle && manifest == nil`
前置条件；`begin()` 检查 `hasUnsettledManifest`，有残留就先请用户处置。

## P1-6 恢复导入没有工程锁，也没有 generation CAS

用户点 Add 后**立刻** `pendingRecovery = nil` 才 await 导入，这期间
coordinator 是 `.idle` —— 允许切工程、开新录制、退出；
`importRecoveredRecording()` 也没有 document generation 校验，
结果可能进错工程。

另有一个确定的状态 bug：partial 入轨失败时 `finishWithFailure()` 没清
`pendingPartial`，弹窗继续挂着，但状态已不是 `.partialRecovery`，
两个按钮都被 guard 挡掉 —— **用户面对一个点什么都没反应的弹窗**。

修法：处置全程走 `.partialRecovery → .importing`（都锁工程切换，
为此在状态机补了 `idle → partialRecovery` 一条边）；
`importRecoveredRecording(_:documentGeneration:)` 跨 await 比对身份；
`finishWithFailure` 清 `pendingPartial`。

## P1-7 stream 异常停止仍绕过采样队列栅栏

`didStopWithError` **先把 `stream` 置 nil**，随后 coordinator 调 `stop()` 时
在 `guard let stream else { return }` 处直接返回，**栅栏根本没执行**。
上一轮加的栅栏对最常见的异常路径（显示器拔出、锁屏）完全无效。
另外回调没带 sessionID，旧 engine 的迟到回调理论上能停掉新会话。

修法：`stop()` **无条件立栅栏**（`stream` 为 nil 也要走）；
`onStreamStopped` 带上 sessionID，coordinator 比对后才处理。

## P1-8 音频成功契约未验证，backlog 还能静默丢尾部

收尾只 probe 主视频，从不验证：开了电脑声音时主文件是否真有音轨、
mic 临时文件是否可读、提交后的最终 URL 是否仍可读。
mic temp 不存在时仍推进 `.allCommitted`（等于宣称两个 rename 都做完了）。
backlog 溢出只累计计数、不按计划立即 Stop；收尾等待超时后剩余的 backlog
**没有计入 partial**。

修法：提交前校验音频契约并汇入 `partialReason`；mic temp 缺失时停在
`mainCommitted` 不推进；溢出触发立即 Stop；超时残留计入 partial；
提交后回读最终文件。

## 三个 P2

- **固定比例矩形在屏幕边缘被裸 `intersection` 裁成任意比例** ——
  用户选的 16:9 悄悄失效。新增
  `ScreenRecordingCoordinateMapper.clampPreservingRatio`（保持比例地收缩+平移）。
- **倒计时三秒界面上什么都不显示**，浮窗只有 00:00 红点，用户以为已经在录。
  控制窗补 `countdown` 显示 3/2/1 + "Starting…"。
- **picker 没设 `allowsChangingSelectedContent = false`**（SDK 默认 YES），
  用户可在录制中换来源，而捕获尺寸/sourceRect 已冻结。

## 本轮新增测试

582 = 555 + 27，全部反证过：

| 反证 | 结果 |
|---|---|
| 比例夹取退回裸 `intersection` | 3 条 FAIL（右越界/下越界/竖向比例） |
| 改址不生效 | 2 条 FAIL |
| 去掉 `idle → partialRecovery` | 1 条 FAIL |

写断言时还抓到自己一个错误假设：`mainCommitted` 阶段问 `microphoneResolution`
本就该得 `notCommitted` —— 我先写成了 `committed`。断言红了才发现。

---

# 第三轮复审：5 个 P1 + 4 个 P2（同日）

## P1-1 恢复状态机的三个断口

- **等用户决定期间没锁工程**：`recoverIfNeeded` 只设 `pendingRecovery`，
  状态还是 `.idle`。修法：新增 `present(_:)`，设 pendingRecovery 的**同时**
  迁到 `.partialRecovery`。
- **处置完永久卡在终态**：`resolveRecovery` 的 `defer` 写的是
  `if state.isBusy { transition(to: .idle) }`，而终点恰恰是 `.finished` /
  `.failed` —— 两者 `isBusy == false`，于是状态停在终态；`begin()` 只接受
  `.idle`，**Record Screen 看着能点、实际永久无反应**。修法：无条件回 `.idle`。
- **退出时 `.partialRecovery` 收不了尾**：`prepareToTerminate` 把它当可异步
  Stop 的状态，`stop()` 却不处理它。用户切离 Edit Video 让 sheet 消失后再退出
  就一直等不到 reply。修法：`stop()` 按**最安全的默认**处置（保留文件、不入轨、
  不删除）后收敛。

## P1-2 损坏 manifest 会被下一次录制覆盖

`hasUnsettledManifest` 用的是 `(try? store.load()) != nil` —— 损坏 JSON 被读成
「没有账本」，下一次 `persist()` 就把它盖掉了。恢复入口承诺「保留并如实报告」
的那份记录，反而死在这里。

修法：新增 `ScreenRecordingManifestStore.fileExists`（纯文件存在性），
「有没有账」一律以它为准。**解码失败同样是 unsettled，不允许 fail-open。**

## P1-3 「仅麦克风可恢复」被塞进必须有视频的模型

主文件无效、mic 有效时，把 `.m4a` 填进了 `ScreenRecordingResult.mainURL`，
而入轨路径必定按视频 probe —— Add 注定失败。计划 §9.2-3 本来就写明
「mic 只有在能与有效主文件建立对应关系时才提示恢复」。

相邻的三处同类问题：`commitRecovered()` 会提交已被 probe 判为无效的主临时
文件；Discard 只删 `result` 里的 URL，留下 manifest 点名但没映射进去的孤儿；
主文件已提交而 mic 缺失时完全不报告 mic 丢失。

修法：`PendingRecovery.kind` 区分 `.recording` / `.microphoneOnly`，纯音频变体
**不提供「加入时间线」**，只给保留/丢弃并展示精确路径（§9.2-4）；
`commitRecovered` 按 kind 跳过无效主文件；Discard 改删
`discardablePaths`（manifest 点名的**全部**临时路径，最终路径一律不删）；
文件已提交时**不提供 Discard**（那已经是用户的文件）。

## P1-4 可选麦克风失败会拖停主录屏

`start()` 里 mic `startWriting()` 失败让整个 `start()` 抛错；
`checkWriterFailure()` 又把两个 writer 的失败写进**同一个** `failure`，
于是 mic 一挂，后续所有画面和系统声音都被 `append` 入口拒收，coordinator
随即停掉整段录制。与计划 §1「mic 失败时主画面和电脑声音继续」直接冲突。

修法：`micWriter` / `micInput` 改成 `var`，新增 `disableMicrophone(reason:)`；
`checkWriterFailure(kind:)` 分流 —— **麦克风的失败绝不写进共用 `failure`**；
收尾时按 partial 如实告知。

## P1-5 音频只验证「有轨」，没验证覆盖录制周期

原来只看 `hasAudio` 与「asset 时长大于零」，而 `audioDuration` 读的是容器总
时长 —— **麦克风产生一个包就断开也能通过**。writer 已经记录的
arrived/written/PTS 完全没参与验收，最终路径也只回读主文件。

修法：`FinishResult` 带上 `lastWrittenSeconds` 与 `microphoneFailure`；
验收改成「写入采样数 > 0」**且**「末端与整段时长之差 ≤ 1 秒」
（`audioCoverageToleranceSeconds`）；两个最终文件都回读。

恢复的删除路径同类问题：删除失败后仍清账 —— 文件还在，账本一清就没人认领。
修法：有删不掉的就报出文件名并**保留账本**，不标 settled。

## 4 个 P2

- **收尾排空最坏 80 秒**（每路 20000 次 × 2ms），磁盘满时表现成「退出卡死」。
  改成两路**共享的 3 秒墙钟 deadline**，且 writer 已失败就立刻收手。
- **倒计时结束后先清 countdown 再等 `startCapture()`**，那段时间浮窗退回
  「红点 + 00:00」，看起来已经在录。改成真正开录之后才清。
- **`ScreenCaptureEngine` 的 `stream` / `stopHostTime` 无隔离读写**
  （`start`、`stop`、delegate 回调三方并发）。`@unchecked Sendable` 只是关掉
  编译器检查，不消除数据竞争。改用 `NSLock` 真正保护，且「取出并置空」在同一次
  持锁里完成。
- **固定比例矩形靠「算完再平移回屏内」夹取，锚点会跳走**。根因是顺序：
  应当**先夹取拖动点、再算矩形**（`regionRect(anchor:current:ratio:bounds:)`），
  这样比例天然保持、锚点天然不动。

## 本轮测试

589 = 586 + 3（比例夹取那组重写为「比例 + 落屏 + **锚点不动** + 拖动方向」）。

反证：

| 反证 | 结果 |
|---|---|
| 退回「先算矩形再平移」 | 4 条 FAIL（含 3 条落屏、1 条尺寸）|
| manifest fail-open | 起初**没抓到** → 说明缺断言，补了 3 条后再反证得 2 条 FAIL |

> 「反证没抓到」本身就是一次有效发现 —— 它说明那条契约当时根本没有守卫。

**实机验证**（植入账本 + AX 探针）：

| 场景 | 结果 |
| --- | --- |
| 恢复框弹出时 | Record Screen **disabled** = 已锁工程（P1-1a）|
| 已提交的残留 | 弹窗只有 2 个按钮，**没有 Discard**（P1-3）|
| 点「Add to timeline」之后 | Record Screen **恢复可用**，再点真的打开设置页（P1-1b；旧代码永久卡在 `.finished`）|

---

# 第四轮复审：6 个 P1 + 4 个 P2（同日）

## P1-1 纯麦克风恢复破坏了 journal 协议

纯音频恢复跳过主文件，却把**全局阶段**推进到
`committingMicrophone`/`allCommitted` —— 而这两个阶段的语义前提正是
「主文件已经提交」，`mainResolution` 会据此无条件认定它已落到最终路径。

确定反例：主临时文件损坏、主最终路径上原本就有**用户自己的**文件、
mic 临时文件有效；用户选保留 mic，落盘 `committingMicrophone` 后崩溃；
重启后**用户那个无关文件会被认成本次录屏**，和 mic 一起提示导入。

修法：新增 `microphoneOnlyCommitting` / `microphoneOnlyCommitted` 两个独立阶段，
`mainResolution` 在其下一律返回 `notCommitted`；被判无效的主临时文件精确删除。

## P1-2 麦克风降级只修了一半

上一轮只修了运行期 append 失败。仍会拖停主录屏的两处：
mic `AVAssetWriter` **构造**抛错让整个 writer 初始化失败；
`addStreamOutput(.microphone)` 或带失效设备 ID 的 `startCapture()` 抛错终止整个 capture。

另外 `commitFiles()` 仍只检查「文件是否存在」就提交并推进 `.allCommitted`，
于是零采样、probe 失败、writer 已知故障却仍残留的 `.m4a`
**会被提交成用户可见的损坏文件**。

修法：构造改 `try?` 并记 `microphoneFailure`；engine 先按完整配置试，
麦克风相关失败就**降级成无麦克风重来一次**；`commitFiles(commitMicrophone:)`
按校验结果决定提交与否，不提交就精确删掉临时文件并停在 `mainCommitted`。

## P1-3 删除失败保护只接到了用户点 Discard 的路径

恢复时两路都不可用、正常 finalize 拿不到有效视频，这两条自动清理仍是
`try? removeItem` 后无条件清账。删除一旦失败，隐藏临时文件还在，账本却没了。

修法：所有自动清理共用
`removeExactly(_:)` → **复核路径确实不在了** → 空数组才允许 settled；
删不掉的由 `reportUndeleted(_:)` 如实报出并**保留账本**。

## P1-4 恢复导入在清账之前就进入 `.finished`

`.finished` 是非忙状态，会立刻触发退出答复。正在 Quit 时进程可能赶在清账之前
退出，下次启动重复提示并**重复入轨**。

修法：清账放在进入解锁态**之前**；再叠一层幂等 ——
用 manifest 的 `sessionID` 当录屏 clip 的 `linkGroup`，入轨前先查它是否已存在。

## P1-5 主文件已提交时静默忽略缺失的 mic

`main == .committed` 提前返回 `.offerImport`，mic 只有恰好 `.committed` 才带上；
UI 构造的结果还写死 `isPartial: false`。于是 mic 两端都丢、`allCommitted` 但 mic
最终文件缺失、mic 预期存在但临时文件没产生 —— 全都被当成完整录制。

修法：`.offerImport` 增加 `microphoneMissing`；缺失时结果判 partial 并明说。

## P1-6 音频覆盖判据仍不满足计划合同

三个问题：没记录**第一份**成功写入的 PTS（开头缺十秒也能过）；
`lastWritten` 在 enqueue 返回后就更新，而 enqueue 只是入队、不代表 append 成功；
容差写死 1 秒，而计划要求末端差不超过**一个工程帧**。

修法：新增 `noteAppended(kind:at:duration:)`，只在 `append` 返回 true 后记录；
维护 `firstAppended` 与 `lastAppendedEnd`（末端用 **PTS + duration**）；
容差改成 `1 / frameRate.fps`，开头与末端同时验。

## 4 个 P2

- `allowsDiscard == needsCommit` 让「主文件已提交、只剩 mic 临时文件」的混合态
  仍显示 Discard。判据改成「**没有任何一路已提交**」。
- 纯 mic 提交后 `mainURL` 仍指向已被移走的临时 `.m4a`，「saved as」文案报错路径。
- 计划里的两个普通偏好补上：麦克风开关/设备记住上次选择、Save 面板回到上次目录
  （`ScreenRecordingPreferences`；**录制真的开始之后**才记目录）。
- 报告里的过期章节（Phase 2「UI 未做」、§7「尚未开始」、验证表「两轮共 16 个 P1」）已刷新。

## 本轮测试

595 = 589 + 6。反证：

| 反证 | 结果 |
|---|---|
| 纯 mic 复用 `committingMicrophone` 阶段 | 2 条 FAIL（`got committed, expected notCommitted`）|
| `offerImport` 忽略 mic 缺失 | 1 条 FAIL |

断言里特意留了对照条（正常 `committingMicrophone` 阶段主文件**确实**已提交），
证明前两条不是恒真。

---

# 第五轮：真机首测（2026-08-08）

前四轮全是**读代码**找问题，595 项自检全绿。第一次真机端到端，5 个问题当场暴露，
**其中没有一个是自检能抓到的**。

## 1. 状态机缺一条边 → 录制永远不会开始

`start()` 走 `.choosingSource → .choosingDestination`，而矩阵里没有这条边。
`transition` 是 `@discardableResult`，**静默返回 false**：状态卡在
`.choosingSource`，保存面板照常弹、控制窗照常建、manifest 照常落盘、writer 照常
建好，然后 `runCountdown()` 的 guard 一看状态不对直接 return ——
**一切都准备好了，就是没按下开始**。没有倒计时、没有报错、什么都没有。

定位靠的是 `defaults read com.srtflow.devbuild screenRecording.lastDirectory`
已经记下了 `/Users/sky/Downloads`：那行代码在「writer 建好之后、倒计时之前」，
说明流程确实走到了那里。（用户随后退出 App，`invalidateSession()` 把临时文件和
账本都清了，所以事后查什么都不剩。）

**自检为什么没抓到**：状态机断言逐条验单边，从没把 happy path 端到端走一遍。
补了 `checkStartHappyPath()`——把 `start()` 的真实 transition 序列一步步走完，
加之前它红 9 条。

## 2. 音频容差取「一个工程帧」→ 每次录制都误报 partial

上一轮复审要求「末端差不超过一个工程帧」，我照做了。但那条要求针对的是**对齐**
验收（解码 PCM 比对拍手峰值，属实机项），我却套到了「首包 PTS」上。
24 fps 一帧 = 41.7 ms，而计划 §8.3 同一段白纸黑字写着 AAC priming ≈ 44 ms
**已经略大于一帧**、且「不能把编码包的首 PTS 直接当同步结论」。

于是只要开电脑声音就必然弹
「Computer audio starts **0:00** after the recording begins」——
差值小到连格式化都显示不出来，这个 `0:00` 本身就是误报的证据。

改成**完整性**判据（`ScreenRecordingAudioCoverage`，容差 0.5 s），
9 条断言钉住边界，反证命中 4 条。

## 3. 控制窗排除依赖广域授权，与 picker 路径的意义相悖

`finalFilter` 为了 `excludingWindows` 去读 `SCShareableContent` —— 那需要**广域**
屏幕录制授权，而 picker 这条路的全部意义就是「只授权用户选中的那块内容」。

改用 `NSWindow.sharingType = .none`：窗口服务器级别，不依赖授权、也没有
「窗口还没进可分享列表」的竞态。**这个改动顺带解锁了录制期区域遮罩** ——
以前做不了正是因为遮罩自己会被录进去。

## 4. 报错被 `lineLimit(1)` 截成半句

权限指引显示成「SrtFlow doesn't have permi**...**on, turn it off and on again.」——
最需要看清的一条，被截得看不出要去哪、做什么。改成两行完整显示。

## 5. 保存位置在系统 picker 之后才问

用户被连着问两次（系统 picker 的 Cancel/Share，再一个保存面板），
不知道自己走到哪一步了。改成在设置页里就选好，预填 `~/Downloads` +
建议文件名，并记住上次目录。

## 顺带确认的两件事

- **系统 picker 的 "Share Entire Screen" 文案改不了。**
  `SCContentSharingPickerConfiguration` 只开放 `allowedPickerModes` /
  `excludedWindowIDs` / `excludedBundleIDs` / `allowsChangingSelectedContent`。
  要换成 "Record" 只能不用系统 picker、自己列来源（代价是必须先要广域授权）。
  **产品决策：保留系统 picker。**
- **Phase 0 的「稳定启动器 + 可变负载」防 TCC 失配方案，对完整 App 不适用。**
  `execv` 之后 `Bundle.main` 变成负载目录，随包 ffmpeg / 资源全部找不到
  （实测报「Video engine needs attention · no libass」）。Phase 0 那个 harness
  没有资源依赖所以没暴露。开发期只能接受「重签 → `tccutil reset` → 重新授权」。

## 可复用的结论

1. **纯函数通过 ≠ 接线正确。** 本轮 8 个 P1 里有 2 个是"函数是对的，没人调用它
   / 调用时给错了坐标系"。写完纯函数要顺手查一次生产调用点。
2. **验证必须在破坏之前。** 任何 rename/覆盖之前先 probe 临时文件。
3. **"用户没确认过的覆盖"一律避让。** Save 面板只授权了主文件那一次。
4. **按钮文案就是合同。** "Keep file only" 就不能删文件。改文案或改行为，
   不能两者不一致。
5. **状态机的 `default:` 是陷阱。** 静默 return 在异步回复协议里等于死锁。
   涉及 reply 的分支要穷举状态而不是留 default。
6. **报错要报到用户看得见的地方。** 弹窗关掉之后才发生的失败，写进弹窗等于没写。
7. **复用工具函数前先读它的前置条件。** `MediaProbe` 无视频轨就抛错，
   拿它探纯音频 sidecar 是必然失败 —— 这类问题编译器不报、纯逻辑自检也不覆盖。
   新建同类对象时，先找仓库里**已有的同类路径**对照字段
   （mic clip 漏 `isAudioOnly` 就是没对照 `addAudio`）。
8. **断言产出正确答案 ≠ 消费端用对了它。** `offerSalvage(main: nil, …)` 的
   nil 被回退成一个不存在的路径，自检全绿而生产代码在删用户文件。
   写完纯函数要顺着**每一个消费点**读一遍它的边界返回值。
9. **「先落意向再动文件」里的「意向」必须包含最终目标。** 只落 stage、
   把目标路径留到 rename 时才决定，等于没落意向。
10. **`if isBusy { 回 idle }` 这类收尾守卫要检查终点。** 终点若是
    `.finished`/`.failed`（两者都不 busy），守卫恰好不生效，状态永久卡住。
    收尾一律无条件回到可用状态。
11. **「有没有 X」不要用「能不能解析 X」代替。** 损坏的账本仍然是账本；
    解析失败必须 fail-closed。
12. **反证没抓到，本身就是发现。** 那说明这条契约根本没有守卫 —— 别放过它。
13. **可选功能的失败不能写进共用的失败态。** mic 与主通道共用一个 `failure`，
    一个可选通道就能拖停整段录制。
14. **端到端走一遍，不能只逐条验单边。** 状态机每条边都验过，却漏了整条
    happy path 里缺的那一条 —— 五轮复审、595 项断言全绿，真机一跑就死。
    凡是「有序流程」，自检里必须有一条把真实顺序完整走完的断言。
15. **别把 A 场景的验收标准套到 B 场景。** 「末端差不超过一帧」是解码 PCM 的
    对齐标准，套到「首包 PTS」上就必然误报 —— 计划里甚至已经写明了原因。
    照搬复审意见之前，先确认它约束的是哪一层。
16. **`@discardableResult` + 静默失败 = 最难查的 bug。** 一切都"成功"了，
    只是什么都没发生。守卫型返回值要么用上，要么让它在开发期显式报警。
17. **异步回调里提前置空句柄，会让后续清理路径整段失效。**
    `stream = nil` 之后 `guard let stream else { return }` 就跳过了栅栏。
    清理动作要么无条件执行，要么用独立于句柄的状态位判断。
