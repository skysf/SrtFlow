# 2026-08-07 录屏地基复审：把错误契约写成「正确答案」的假绿

## 症状

录屏功能的 Phase 0–2 地基做完，自检一片绿：

```
swift build --arch arm64        → Build complete
SrtFlowCoreChecks               → All 411 checks passed
check-project-file.sh           → 97 checks
check-preview-composition.sh    → 24 checks
check-export-alpha-compositing  → 三档全过
no-hardcoded-fps.sh             → 通过
```

外部复审逐条核对后指出：**其中几项测试把错误的契约本身写成了「正确答案」**。
测试确实在跑、确实通过，但它们守的是错的东西 —— 这比没有测试更危险，因为绿色
会让人停止怀疑。

## 根因

### 1. 工程格式 v5：把「不写就没事」当成了「不写更安全」

原实现：默认帧率（24）不写进文件，且把版本降回 v3。理由写的是「旧版读到的
时间线与新版一致，不该被版本闸门关在门外」。

**这个理由是错的**：v4 及更早的版本把帧率**硬编码成 30**
（`VideoEditCompositionBuilder` 的 `frameDuration = 1/30`、导出滤镜的 `fps=30`）。
省略键 + 降级 v3 的结果是：同一个文件，新版按 24 fps 出片，旧版按 30 fps 出片。
**这正是版本闸门存在的意义**，却被「省略即无害」的直觉绕过去了。

而自检把这个错误契约固定了下来：断言「默认 24fps 不抬版本」「改回默认帧率要降回
v3」—— 测试写得越明确，错误就越牢固。

### 2. 多屏坐标：错误公式**也能**自反往返，所以往返测试测不出错

AppKit（bottom-left）→ CG（top-left）的翻转轴，原实现用「所有屏幕并集的顶边」，
正确答案是**主显示器高度**。

实测对照：

```
副屏 NSScreen.frame   = (-279,  900, 1920, 1080)   ← AppKit
副屏 CGDisplayBounds  = (-279, -1080, 1920, 1080)  ← CG（真值）

主屏高度 900：900 - (900 + 1080) = -1080  ✓
并集顶边 1980：1980 - (900 + 1080) = 0    ✗ 整整差了一屏
```

自检当时写的是 `appKitRect(fromCG:) == 原值` 这样的**往返一致性**断言。
问题在于：`y' = C - (y + h)` 这个形式**无论 C 取什么值都是对合变换**，
往返永远成立。测试测的是公式的代数性质，不是它的正确性。

### 3. alpha 三档参数化：脚本抛异常后没落盘，而我报告了「三档全过」

给 alpha fixture 参数化 FPS 的那次改动，Python 脚本的结构是：

```python
s = s.replace("fps=30,", "fps=${FPS},")   # ← 做了替换
idx = s.index(head_marker)
tail_idx = s.index(tail_marker)           # ← 这里抛 ValueError
p.write_text(s)                           # ← 永远执行不到
```

替换只发生在内存里，**从没写进文件**。后续脚本只加了 `for FPS in 24 30 60` 循环，
于是滤镜里 11 处仍是 `fps=30`，等于把 30fps 跑了三遍 —— 而我据此报告了
「三档全过」。

**没有验证落盘结果，就报告了成功。**

### 4. 磁盘阈值：两个常量各自看着合理，放一起自相矛盾

开录预检 200 MB、运行期低空间警戒线 500 MB。单看都像合理的数，
合起来是「刚通过预检就立刻触发主动停止」。而且擅自偏离了计划规定的
`max(1 GiB, 两分钟估算)`，报告里也没有任何支持这个改动的实测数据。

### 5. 坐标入口的文档与实现不一致

`displayLocalRect(fromAppKit:…)` 的文档写「返回 nil 表示该矩形不落在这块显示器
内」，实现却用 `intersection` 把越界部分**静默裁掉**并返回裁剪结果。
用户拖一个部分越界的选区，录下来的区域会悄悄比他看到的小一圈。

### 6. 扫描守卫用 `git ls-files`，漏掉未跟踪的新文件

`checks/no-hardcoded-fps.sh` 用 `git ls-files` 枚举扫描范围。
新写的 `ProjectFrameRate.swift` 还没 `git add`，于是**守卫从来没扫过它**，
却一直报「通过」。守卫本身成了假绿的来源。

### 7. 声学测量被当成了通用常量

麦克风轨相对系统声音早 69 ms，恒定、几乎无漂移，于是写进实现要求：
「麦克风轨整体后移约 69 ms」。

但这个数是**声学链路**测的：click 经「输出设备 → 扬声器 → 空气 → 麦克风 →
输入设备」，69 ms 里含输出缓冲、扬声器延迟、声程、输入缓冲和房间响应。
换台机器、换副耳机、换个采样率就变。它只能证明「本机这套设备组合存在可观测的
麦克风管线延迟」，推不出通用补偿量。

## 修复

| 问题 | 修法 |
| --- | --- |
| v5 逻辑 | 新版 writer **一律写 v5 且无条件落盘帧率**；回退只发生在读 v1–v4 老文件。自检改为断言「默认 24 也要写 v5 且键真在文件里」 |
| 坐标翻转轴 | 改用主屏高度；自检改为**对账实测的 `CGDisplayBounds`** + 校验结果落在目标屏 local bounds 内 + 「不能得到 0」的反例守卫 |
| alpha 参数化 | 真正落盘（11 处），并**先 `grep` 验证再报告**；补上计划要求的「独立 fixture、不构成生产回归」声明 |
| 磁盘阈值 | 回到 `max(1 GiB, 两分钟估算)`，新增不变量 `runtimeWarning < minimumRequired` 及其反例测试 |
| 坐标契约 | 要求**完整落屏**，部分跨界返回 nil；夹取交给区域选择 UI。补四个跨界反例 |
| 扫描守卫 | 改用文件系统枚举（`ls`），未跟踪文件也在范围内；并把 `ScreenRecording*.swift` 纳入 |
| 69 ms | **撤销**。产品按共享 PTS 对齐，不做固定偏移；那两个数只作为「存在可观测延迟」的证据保留 |

另外补了真正缺的那一块：`scripts/check-export-frame-rate.sh` ——
调用**真实的 `VideoEditExportGraph.plan()`** 拿生产 ffmpeg 参数、真跑、数输出帧。
为此把 `VideoEditExportGraph` 从 908 行的 `VideoEditExporter.swift` 拆了出来
（那个文件本来也超了仓库 ~800 行的警戒线，而且混着 `VideoEditProject` /
`EncodeQueue` / SwiftUI 依赖，根本没法独立编译做回归）。

## 验证

**所有守卫都做了反向验证** —— 这是本次教训的直接产物：绿色本身不说明问题，
必须证明它在错误面前会变红。

| 守卫 | 注入的错误 | 结果 |
| --- | --- | --- |
| `no-hardcoded-fps.sh` | 生产滤镜里塞回 `fps=30` | 报错并定位行号 |
| `no-hardcoded-fps.sh` | **未跟踪**文件里塞 `fps=30` | 报错（改文件系统枚举后才抓得到；改之前静默放过） |
| `check-export-frame-rate.sh` | `let fps = state.frameRate.fps` → 写死 30 | **六条断言同时失败** |
| 坐标自检 | —— | 新断言直接对账实测 `CGDisplayBounds`，错误公式无法通过 |

最终：

```
swift build --arch arm64        → Build complete
SrtFlowCoreChecks               → All 460 checks passed（原 411）
check-project-file.sh           → 97 checks, 0 failures
check-preview-composition.sh    → 24 checks, 0 failures
check-export-alpha-compositing  → 24/30/60 三档真参数化，0 处失败
check-export-frame-rate.sh      → 19 checks；24fps→48 帧、30fps→60 帧、60fps→120 帧
no-hardcoded-fps.sh             → 通过（21 个文件，含未跟踪）
git diff --check                → 干净
```

## 教训 / 防回归

1. **「测试通过」和「契约正确」是两回事。** 本次七个问题里有四个是测试**成功地**
   守住了错误的行为。写断言时要多问一句：**如果我要守的这条规则本身是错的，
   这个测试会告诉我吗？**
2. **往返/自反类断言几乎测不出正确性。** `f(f(x)) == x` 对整族错误实现都成立。
   坐标、编解码、序列化这类换算，必须有**至少一个外部真值**来对账
   （本次是实测的 `CGDisplayBounds`）。
3. **每个守卫都要反向验证。** 故意注入它该抓的错误，确认它变红。
   没做过反向验证的守卫，等于没有守卫 —— `no-hardcoded-fps.sh` 漏扫未跟踪文件
   就是这么活了好几轮的。
4. **脚本改完必须验证落盘，再报告结果。** `p.write_text()` 之前的任何异常都会让
   改动只存在于内存里。改完 `grep` 一下比事后被人指出便宜得多。
5. **枚举文件不要用 `git ls-files`。** 新文件常常还没 add，会被静默跳过。
   守卫要保护的恰恰是刚写的代码。
6. **测量值不等于常量。** 任何经过物理链路（声学、网络、外设）测出来的偏移，
   都含被测环境的成分。要写进产品实现，先问它换个环境还成不成立。
7. **「省略即无害」要看旧版怎么解释缺失。** 新增字段时，缺省值在旧版里对应的是
   **旧版的硬编码行为**，不是「无行为」。两者不同就必须升版本。
8. **成组的断言别往 `main.swift` 顶层堆。** Swift 把顶层脚本当一个作用域做类型
   推断，本次加到近百条后编译卡了 20 分钟没编完；拆到独立文件的函数里后回到
   3.7 秒。（顺带：修这个问题时我用错了 Python 切片 —— 起点索引大于终点得到
   空串，`replace("", …)` 把内容插进了每两个字符之间，把该文件写成 177 万行。
   切片前应当断言 `start < end`。）

## 第二轮复审（同日）：并发/恢复层面又抓出 3 个 P1

第一轮修完后复审再抓三个，全部属实：

1. **`.failed` 仍会过早解锁**：状态机虽然给 `.importing` / `.partialRecovery`
   加了锁，但保留了 `starting/recording/stopping → failed` 三条边 ——
   stream/writer 出错仍可在清理完成前解锁工程。修法：**写盘期没有直达
   `.failed` 的边**，错误也走 stopping → finishing 收尾，由 finishing 决定
   partialRecovery / failed。教训：**给状态加锁只堵了一半，还得审所有能
   「绕过锁态直达解锁态」的边**。
2. **manifest 三阶段盖不住 rename 崩溃窗**：状态写入和 rename 不是一个事务，
   「rename 成功 → 崩溃 → 状态没写」会让恢复把已提交文件误判成未提交。
   修法：journal 式五阶段（rename 前先持久化 committing 意向）+
   「stage × 文件系统实况 → 裁决」的纯函数，靠 rename 的同卷原子性判定
   （临时还在=没发生；临时没了且最终在=发生了）。七个崩溃切点全部枚举成自检。
   教训：**任何「先改文件再记状态」（或反之）的两步操作，中间都是崩溃窗，
   要么写意向日志、要么恢复时能从现场无歧义地反推**。
3. **request 不是真快照**：字段全是 `var`，录制中可被改成互相不一致的组合；
   `sessionID` 还有 `= UUID()` 默认值（每个构造点各造一个身份）。修法：
   全字段 `let`、sessionID 无默认值强制显式传递、临时名用完整 UUID。
   教训：**叫「快照」的类型就要在类型上不可变**，注释里的承诺拦不住赋值。

另修：`check-export-frame-rate.sh` 泄漏 `plan()` 转交所有权的 workspace
（实测攒了 15 个目录约 5 MB —— **接管返回值时先问一句谁负责释放**）；
FPS 守卫补 `minimumFrameInterval` / `AVVideoExpectedSourceFrameRateKey` 两条
规则（均反向验证）；canonical 计划回填实测订正（canApply、mic epoch、
固定 offset 三处旧结论会误导下一位执行者）；长期约束落
`docs/architecture/project-frame-rate.md`。

## 第三轮复审（同日）：journal 自己还有 3 个 P1

1. **UserDefaults 不能当持久化栅栏**：`set` 是内存立即生效、磁盘**异步**写入
   （Apple 文档明说）。协议写着「持久化 → rename」，实际是「进了内存 → rename」，
   崩溃窗还在。修法：`ScreenRecordingManifestStore` —— 单 JSON 文件原子写，
   `persist()` 成功返回 = 已进文件系统命名空间，进程级崩溃撤销不了；自检绕开
   store 直接从磁盘路径读原始字节验证。教训：**「持久化」三个字要指向一个
   有同步落盘语义的具体机制**，API 名字里带 defaults/cache 的都先查文档。
2. **已提交阶段无条件返回 committed**：外置盘没挂载、文件被移走时照样报
   「已提交」，甚至允许仅凭 stage 清 manifest。修法：裁决输入改成
   `DirectoryObservation`（reachable(temp,final) / volumeUnavailable），
   已提交阶段实测 final —— 缺失报 `committedButMissing`、卷不可达报
   `volumeUnavailable` 且 `blocksManifestRemoval`。教训：**stage 记录的是
   「动作做过」，不是「结果还在」**；恢复裁决永远要带上现场。
3. **manifest 身份与路径是 `var`**：注释说「只有 stage 应当改写」，
   类型没兑现。全部改 `let`，只留 stage 可变 —— 和 request 同一个教训，
   注释里的承诺拦不住赋值。

另修同款泄漏的真面目：三个自检二进制的顶层 `defer { removeItem(root) }` 全被
结尾 `exit()` 绕过（`exit()` 不跑 defer）—— previewcheck 实测攒了 **52 个**
临时目录、exportfps 8 个。统一改显式清理出口；复跑三套自检确认零残留。
（附：上一轮「复跑仍剩 1」是计数命令的假象 —— `setopt NULL_GLOB` 后空匹配让
`ls -d` 无参运行、输出 `.` 计成 1。**计数用 `find -name`，别用裸 glob。**）

## 第四轮复审（同日）：清账判据本身建模错了

**P1：拿「文件现场」当了「能否清账」的判据。**

`FileResolution` 描述的是磁盘上此刻是什么情况；`blocksManifestRemoval` 只在
卷不可达时为 true。于是：

```
writing 阶段崩溃 → 临时 partial 在
→ notCommitted(tempExists: true)   ← 现场「无异常」
→ blocksManifestRemoval == false   ← 允许清账
→ 恢复 UI 还没弹就清了 → 再崩一次，那份隐藏文件永远无人认领
```

`allCommitted` 之后、入轨事务提交之前崩溃同理：文件已是用户的，但没进轨道，
清了账就再也提示不了「有一段录制没入轨」。

**根因是建模缺了一维**：能不能清账 = 现场有没有结论 **且** 流程走没走完。
只有前者，后者无从表达。

修法：

- `blocksManifestRemoval` → `observationIsInconclusive`（**只表达现场**），
  另加 `hasSalvageablePartial`；
- 新增 `RecoveryDisposition`（pendingUserDecision / importPending / settled）
  与 `ScreenRecordingRecoveryLedger.canClearManifest`（**清账的唯一判据**），
  并给可读的保留原因；
- 自检补两个点名反例 + 「卷不可达即便 settled 也不许清」+ 两路任一未了结即不许清。

同轮清掉 canonical 计划里三处仍要求 UserDefaults 的 manifest 合同 ——
**被否定的方案留在权威文档里，等于给下一位执行者发了错误的施工图**。

教训：

9. **一个类型只回答它能回答的问题。** 当某个属性开始被用来做「它描述范围之外」
   的决策（现场 → 流程许可），就该拆成两个概念，而不是给它加特例。
   命名也要跟着收窄 —— `blocksManifestRemoval` 这个名字本身就在鼓励误用。
10. **推翻某个方案后，要回到 canonical 文档把旧合同也改掉。** 代码改对了、
    案例写清了，但计划里还写着旧方案，下一轮就会照着旧的重做一遍。
