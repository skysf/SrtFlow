# 2026-08-09 PR#22 复审四连 + 二轮两连 + 三轮一连：忘升格式版本、检测敢猜、metadata 绕开可听合同、选择不互斥

- **日期**：2026-08-09
- **来源**：PR #22（`fix/subtitle-panel-translation-and-track-ux`）合并前复审。
  第一轮 base..b72a30b 三个 P1 + 一个 P2；**第二轮又在第一轮的修复上抓出
  两个 P2**（都在 Auto-detect 路径）；**第三轮又在第二轮的修复上抓出一个 P2**
  （取消被跳过逻辑吞掉）。均未发布即修复
- **相关**：[2026-08-09-subtitle-translate-after-same-language](2026-08-09-subtitle-translate-after-same-language.md)
  （本次是它的 follow-up）、
  [architecture/video-edit-project-file](../architecture/video-edit-project-file.md)、
  [architecture/subtitle-language-flow](../architecture/subtitle-language-flow.md)、
  [architecture/subtitle-track-visibility-and-layout](../architecture/subtitle-track-visibility-and-layout.md)、
  [2026-08-04-transform-review](2026-08-04-transform-review.md)（同一个「忘升版本」的坑）

## 症状

1. **[P1] 用旧版打开新工程，字幕排版被静默删光。** 新版把 `subtitleLayout`
   （位置/换行宽度/字号倍率）和 `subtitleHidden`（眼睛）存进工程，但
   `latestFormatVersion` 还是 5。只认 v5 的旧版照常打开，用户随手编辑一下
   触发自动保存 —— 两个键消失，字幕位置/宽度/字号回默认，**导出画面跟着变**；
   本来设了「不要烧字幕」的工程还会把字幕烧进成片。
2. **[P1] 自动检测把错误模型判成成功。** 只装了中文模型的 Mac 上放英文视频，
   Auto-detect 会「成功」选中中文，整轨按中文模型生成一串乱码字幕 ——
   用户看到的是「字幕生成完成」，不是「检测不出来，请手选」。
3. **[P1] 隐藏的主轨仍在替素材「指定语言」。** 隐藏英文主轨 + 可听日文
   overlay 的工程：检测拿英文当最高优先级候选（还是唯一允许触发模型下载的
   那个），探针却抽的是日文 overlay。
4. **[P2] 先点形状、再点字幕 cue，预览上同时挂两套框。** 反方向同理；
   切工程之后，上一条工程的 cue 选择还留着。

## 根因

### 一、`latestFormatVersion` 又忘了 +1

2026-08-04 的 transform 评审已经把这条写死过：**判断要不要升版本，问的不是
「新版能不能读旧文件」，而是「旧版拿到新文件会不会毁数据」。** 这次两个字段
都走了宽容 Codable（缺键回退），于是「新读旧」一路绿灯，
`subtitle-track-visibility-and-layout.md` 里甚至白纸黑字写着
「`subtitleHidden` 走宽容 Codable，不升 formatVersion」—— 宽容解码只解决
一个方向，另一个方向只有版本闸门能拦。

更糟的是自检**帮着守住了错误行为**：`checks/ProjectFile` 里有一条
`check(VideoEditProjectFile.latestFormatVersion == 5, "reader 上限应是 v5")`。
拿常量跟自己比是自反断言，版本忘了升它照样绿，还顺手把「v6 必须拒开」钉成了
合同 —— 正是 2026-08-07 那轮点名的假绿形态。

### 二、阈值订在了错误模型的分数之下

`minimumConfidence = 0.45` 的注释写着「只兜『候选里没有正确语言』」。但同一
批实测数据里，错误模型（zh_CN 转英文音频）的加权分是 **0.55**，实测上限
**0.74** —— 全都在 0.45 之上。所以「兜底」从来没兜住过：
`pick([wrongModel])` 会自信地返回它。没有 confidence 的词按中性 0.5 计，
同样过线，于是「系统一个证据都没给」也算检测成功。

生产代码还有第二道口子：`candidates.count == 1` 时**整段探针跳过**，直接采用。
候选表是「这台 Mac 装了哪些模型」决定的，跟素材说什么语言毫无关系 ——
只装一个模型时，任何语言的视频都会被判成那个语言。这与架构文档写的
「候选之外的语言检测不出来，失败文案必须引导手选，不许硬猜」直接冲突：
文档说不许硬猜，实现留了一条零证据的捷径。

### 三、`metadataLanguageTag` 自己又扫了一遍时间线

`TranscriptionTask.detectSourceLocale` 已经收到过滤后的 `[SoundClip]`
（`soundClips(in:)` 复刻的可听合同），但 `metadataLanguageTag(state:)` 拿的是
`state.mainClips + state.audioTracks.flatMap(\.clips)`：不理 `mainHidden`、
不理 `lane.isHidden`、不理 `isMuted`/`volume`，还整个漏掉带声音的 overlay。
这是 2026-08-06 案例「可听性只有一份合同」教训的原样复发 —— 那次刚把
`soundClips(in:)` 抄成合同，这次新增的消费者又自己发明了一套子集。

### 四、互斥规则散在三个地方，漏了两条边

`selectedClipIDs.didSet` 清 shape、`selectedShapeID.didSet` 清 clip、
`selectSubtitleCue` 清 clip —— 三处各写各的，谁也没负责 shape ↔ cue 这一对。
`closeCurrentDocument` 手抄了两行清理，字幕 cue 是后加的字段，没人回去补第三行。
**只要互斥是靠「每个入口自己记得清」实现的，加第三类选择的那天就一定会漏。**

## 修复

### 一、工程格式升到 v6

- `VideoEditProjectFile.latestFormatVersion` 5 → 6，版本史补齐 v5/v6 两行。
- `TimelineState.requiresFormatVersion6` 新登记项：`subtitleLayout` +
  `subtitleHidden`（`VideoEditFormatVersion.swift`，判据注释写清「为什么这两个
  字段旧版丢了会毁数据」）。writer 一律写 latest（v5 起的既有政策），
  v1–v5 继续宽容读取。
- 自检重写：写盘版本号一律**写死 6**（外部真值，不引用常量）；新增
  「v6 往返布局+隐藏」「v5 老工程缺两个键 → layout=nil / hidden=false，
  且既有字段照常读回」「v7 必须拒开」；删掉 `latestFormatVersion == 5` 那条
  自反断言。

### 二、检测改成 fail-closed

- `SubtitleLanguageDetection.minimumConfidence` 0.45 → **0.80**。取值理由写进
  注释：判别区间是实测的 (0.74, 0.91)，0.80 落在中段偏保守一侧，离错误模型
  上限留 0.06、离正确模型下限留 0.11。**并且把这两个边界做成断言** ——
  以后谁想调这个数，先得让 `minimumConfidence > 0.74` 和 `<= 0.91` 两条过。
- 无置信度的中性分抽成具名常量 `unknownConfidence = 0.5`，配一条结构性断言
  `unknownConfidence < minimumConfidence`：**「系统没给证据」永远不许过线**。
  平台哪天整体不回报置信度，全候选一起跌到 0.5 → 检测失败 → 引导手选，
  这正是 fail-closed 要的结局。
- 删掉生产代码里的 `candidates.count == 1` 捷径：**候选只有一个也要过探针**。
- 短素材策略保持不变但写明白：词数不足时退回全体比较，放宽的只是「谁有资格
  参赛」，置信度门槛一步不让。

### 三、metadata 只消费冻结的可听快照

- 新文件 `SubtitleGen/SubtitleAudibleClips.swift`：把 `SoundClip` /
  `soundClips(in:)` 从 `TranscriptionTask` 搬出来（那个类是
  `@available(macOS 26)` 的 `@MainActor` 状态机，自检编不动），再加探针挑选与
  metadata 查询顺序（**探针打头**）。
  > 第一版这里叫 `detectionSources(in:)`，只看 `fileExists` 就定死探针 ——
  > 第二轮复审把它拆成了 `probeOrder` + `selectProbe` + `metadataOrder`，
  > 见下面「第二轮复审两连」的第五条。
- `metadataLanguageTag(state:)` → `metadataLanguageTag(in clips: [SoundClip])`；
  `detectSourceLocale` 的 `state:` 参数**直接删掉**。它在类型上就够不着
  `TimelineState`，也就不可能再分叉出第二套声音来源 —— 比注释和 code review
  都可靠。

### 四、互斥收进一个值类型

- 新文件 `VideoEditSelection.swift`：`EditSelection` 三个字段全
  `private(set)`，唯一的改法是 `selectClips` / `selectShape` /
  `selectSubtitleCue` / `clear` / `pruneClips` / `pruneSubtitleCue`。
  每个 select 都清另外两类，**漏边在类型层面不可能发生**。
- `VideoEditProject` 的 `selectedClipIDs` / `selectedShapeID` /
  `selectedSubtitleCueID` 改成它的计算属性门面（`@Published var selection`
  负责发通知），所有既有调用点一字不改。
- `closeCurrentDocument` 改调 `clearSelection()`；预览空白点击、时间线空白
  点击也统一成它（时间线原本漏 cue、预览原本漏 shape，现在两边同一语义）。
- 失效 cue 的清理挂在 `state` 的 `didSet` —— 时间线的**所有**写入都经过那里，
  删字幕轨 / 外挂新 .srt / 重新生成换掉整轨 cue 身份时自动摘掉旧选择。
  只在真选着 cue 时才遍历，拖布局框那种高频写入不额外付代价，
  **一步撤销的语义（liveApply + endLiveEdit）没有改动**。

## 验证

### 自检（全部做过反向验证，先红后绿）

| 撤掉的修复 | 实测红的条数 |
| --- | --- |
| `latestFormatVersion` 6 → 5 | ProjectFile **8** 条（写盘版本号那批全线红） |
| 版本闸门放开成 `<= 99` | ProjectFile **2** 条（v7 拒开 + 未来版本拒开） |
| `subtitleHidden` 缺键回退改 true、`subtitleLayout` 不落盘 | ProjectFile **4** 条 |
| `minimumConfidence` 0.80 → 0.45 | SrtFlowCoreChecks **9** 条 |
| `soundClips` 退回旧的「扫 mainClips+audioTracks、不看隐藏/静音」 | ProjectFile **5** 条 |
| 探针不看 fileExists、metadata 不以探针打头 | ProjectFile **2** 条 |
| `EditSelection` 退回散装互斥（漏两条边 + clear 漏 cue + 不 prune） | ProjectFile **4** 条 |
| 把 `candidates.count == 1` 捷径加回去 | 接线守卫红 |
| `closeCurrentDocument` 改回只清剪辑 | 接线守卫红 |
| `soundClips` 退回 `info == nil 当有声音` | ProjectFile **1** 条 |
| `selectProbe` 退回「只试第一段」 | ProjectFile **9** 条（含真实媒体 4 条） |
| 吞掉 `InfrastructureError` | ProjectFile **1** 条 |
| 候选去重退回按 locale 标识符 | SrtFlowCoreChecks **3** 条（复现 `["en_US","en_SG","en_IN"]`） |
| `TranslationPreflight` 自己再实现一套 maximal 比较 | 接线守卫红 |
| 已装语言那一档不排序 | 接线守卫红 |
| `selectProbe` 三处取消检查全撤 | ProjectFile **6** 条 |
| 只撤「吞错误前查取消」+「返回 nil 前查取消」 | ProjectFile **2** 条 |
| 只撤「每轮开头查取消」 | ProjectFile **2** 条 |
| `selectProbe` 不收 token 的取消通道 | 接线守卫红 |

**接线守卫**（新增，挂在 `scripts/check-project-file.sh` 末尾，不单开
check-all 条目）：自检编不动 `VideoEditProject` / `TranscriptionTask` 这两个
App 类型，所以「函数被没被调用、参数对不对」在源码层面钉住 —— 要求
`selection = EditSelection()`、`pruneSubtitleCueSelection()`、
`clearSelection()`、`SubtitleAudibleClips.selectProbe(`、
`AudioWindowReader.extract(`、`metadataOrder(in: clips, probe:`、
`metadataLanguageTag(in clips: [SoundClip])`、`selectCandidates(`、
已装档的 `.sorted()`、`guard clip.hasAudio else`、
`TranslationPreflight` 对 Core `languageKey` 的委托都存在；禁止
`state.mainClips + state.audioTracks`、`candidates.count == 1`、
`candidates.count < 3`、`if let info = clip.info, !info.hasAudio`、
`TranslationPreflight` 里的 `maximalIdentifier` 再出现。
这一条直接冲着 2026-08-07 Phase 2–4 的病根去：**纯函数写对了但没被接上**。

### 命令

- `swift build --arch arm64`：零错误（仅既有的 NSEvent Sendable 警告）。
- `scripts/check-all.sh`：**11 项全绿**（脚本当前就是 11 项，本次没有新增
  第 12 项 —— 接线守卫并进了 project-file 这一项里）。
  - `SrtFlowCoreChecks` 691 项、`check-project-file` 192 项、
    `check-translation-preflight` 8 项。
  - `check-project-file.sh` 现在**要用 ffmpeg**（真实媒体探针那组现造素材），
    与其他真跑 ffmpeg 的自检同一套纪律：找不到就明确失败，不静默跳过。
- `git diff --check`：干净。

### GUI 冒烟（真实窗口，2026-08-09，macOS 26）

按 docs/testing/gui-smoke-testing.md：`SrtFlowDev.app`（改名 + ad-hoc 签名）+
`SRTFLOW_SMOKE_VIDEO=tone.mp4:tone.srt`。素材是 vendor/ffmpeg 现造的
**25s testsrc2 + 440Hz 纯音调（无人声）+ 3 条 cue 的 .srt** —— 纯音调正是
「检测不出来」的低可信素材。按窗口 ID 截图，每次注入后截图核实再走下一步。

1. **shape → cue**：Add ▸ Rectangle（形状当场选中，预览出现八把手变换框、
   检查器显示 Rectangle）→ 点轨道上第一条 cue → **变换框消失**、字幕拖框出现、
   检查器回到 Project、播放头跳进该条（0:01.1）。
2. **cue → shape**：接着点预览里的矩形 → **字幕拖框消失**、变换框回来、
   轨道上 cue 取消高亮。两向互斥都是一套框，没有并存。
3. **布局调整 → 存盘 → 重开**：拖字幕框体上移 → ⌘S 存成
   `~/Movies/smoke-pr22.srtflowproj`。文件实测
   **`formatVersion = 6`**、`subtitleLayout = {marginLeft 80, marginRight 80,
   marginBottom 381, fontScale 1}`（默认 marginBottom 是 54，381 就是这次拖上去
   的量）。File ▸ New Project（空工程，**无残留选择**）→ 从 Recent Projects
   重开 → 字幕仍渲染在抬高后的位置，且**没有**悬空拖框。
4. **隐藏字幕不预览/不烧录**：点字幕轨眼睛 → 图标变 eye.slash（橙）、行灰显、
   预览字幕消失。导出面板出现橙字
   「Subtitle track is hidden — nothing will be burned.」。**真跑了一次导出**，
   对产物 2.0s 处抽帧（cue 1 的区间是 1–4s）：画面里**没有字幕**，但那个矩形
   形状**烧进去了** —— 证明叠层管线确实在跑，字幕的缺席来自 `subtitleHidden`
   而不是「什么都没渲染」。
5. **Auto-detect 低可信引导手选**：Source language 保持 Auto-detect →
   Generate Subtitles → 确认替换 → 探针跑完后面板出红字
   **「Couldn't confidently detect the spoken language. Pick it in the panel
   and generate again.」**，时间线上原有的 3 条 cue **原封不动**（没有被一轨
   乱码顶掉）。

**这次冒烟没有覆盖到的**（如实记录，别当已验证）：

- 冒烟证明的是 fail-closed **这条路走得通**；「阈值 0.45 会放行错误模型」和
  「单候选直接采用」这两个具体回归由自检 + 反向验证钉住，纯音调素材区分不了
  它们（无人声时词流本来就空）。
- 「隐藏的英文主轨 + 可听的日文 overlay」这个 metadata 反例没有真机复现 ——
  需要两份带不同音轨语言 metadata 的真实素材，本次只由 checks/ProjectFile 的
  可听快照用例 + 接线守卫覆盖。
- 「调整后导出的烧录位置/宽度/字号与预览逐像素一致」不在本次范围（原有
  人肉清单里的条目，仍待发版前过）。
- **第二轮那两个 P2 没有可区分的真机冒烟**：试过「无音轨主轨 + 音频轨」的
  工程，但撤掉修复重跑输出一样（`MediaProbe` 会把 `info.hasAudio` 填成 false，
  旧过滤器同样排除它）——详见「第二轮复审两连」里的记录。这两条**只由自检
  覆盖**，其中真实媒体那组绕开 `MediaProbe` 直接构造 `SoundClip`，撤掉修复
  实测红 9 条。

## 第二轮复审两连（第一轮修复自身的缺口，都在 Auto-detect 路径）

上一轮把「素材从哪来」收进了 `SubtitleAudibleClips`，但收得不彻底 ——
两个问题都长在那次修复自己的新代码上。

### 五、[P2] 探针只验证「文件存在」，没验证「音轨可读」

**症状**：时间线第一段是个**没有音轨**的视频（或半截文件），后面跟着一条
正常的音频轨。Auto-detect 当场失败报「素材读不了」，可用户手里明明有声音。

**根因**：`detectionSources` 用 `FileManager.fileExists` 挑第一段就定死探针，
`detectSourceLocale` 只抽这一段、不重试；`AudioWindowReader` 对无音轨素材抛
`ReadError`，一路上抛掐死整个检测。**「文件在」和「音轨读得出来」是两回事**，
而上一轮把便宜的预筛当成了判据。

同一处还有第二个口子：`soundClips` 写的是
`if let info = clip.info, !info.hasAudio { return }` —— `info == nil` 被当成
**有声音**。而 `EditClip.hasAudio`（CompositionBuilder / ExportGraph 用的那个）
是 `isAudioOnly || (info?.hasAudio ?? false)`，nil 算**没声音**。宽容解码读回来
的老工程、探测还没回来的导入中素材全是 `info == nil`，于是「可听性只有一份
合同」在刚抽出合同的那次修复里就又分叉了一次。

**当时的守卫为什么没抓到**：`checks/ProjectFile` 的 `makeFile` 只写重复字节，
假文件连真实解码那一关都过不了 —— 它测得出「文件在不在」，测不出
「存在 ≠ 可读」。

**修复**：
- `soundClips` 改用 `guard clip.hasAudio`，与 CompositionBuilder 同一个属性。
- `detectionSources` 拆成 `probeOrder`（便宜预筛：文件存在的，按快照序）+
  `selectProbe`（**逐段真的抽一次**，第一段抽成功才算定下探针）+
  `metadataOrder(in:probe:)`（探针定下来**之后**才查 metadata）。
- `selectProbe` 的错误分流照 `collectWindows` 的责任面：素材自己的错记进
  `skipped` 换下一段，`InfrastructureError` 与取消**直穿**。跳过的素材名进
  `skippedAssets`，面板照实说。
- 新增**真实媒体守卫**：`check-project-file.sh` 用 ffmpeg 现造一个真的没有
  音轨的 mp4 + 一段真有声音的 m4a（造完还验一遍音轨在不在），把生产的
  `AudioWindowReader.extract` 接进 `selectProbe` 跑 —— 无音轨那段被跳过、
  探针落到后面的音频、CAF 真的写出来且不是空壳。

### 六、[P2] 同语言的地区变体吃光三个候选名额

**症状**：本机实测生产算法取到 `["en_US", "zh_CN", "en_IN"]`；第一轮的 GUI
冒烟也已经观察到 `en_US` / `en_SG` 同时参赛。三个名额被英语变体占掉两个后，
即使装了日语模型也可能根本探不到日语。

**根因**：候选去重用的是**完整 locale 标识符**（`seen.contains(matched.identifier)`），
而 `en_US` / `en_SG` / `en_IN` 在裁决层面等价 —— 变体之间的置信度差是噪声
（这一点第一轮的冒烟记录里已经写下来了，却没有反推到去重逻辑上）。
第二个因素是顺序：`installedLocales()` 的返回顺序本机连续两次读都可能不同，
截断发生在一个不确定的序列上，「哪三个语言进探针」会随机漂移。

**修复**：
- 新增 `SubtitleLanguageDetection.languageKey(of:)` —— maximal 化后的
  **语言码 + 文字系统**，和翻译的同语种预检是**同一份实现**
  （`TranslationPreflight.isSameTranslationLanguage` 改成委托过去，
  `check-translation-preflight.sh` 随之链接 SrtFlowCore）。所以 zh-Hans ≠
  zh-Hant、yue ≠ zh 在检测和翻译两边一致。
- `selectCandidates(_:limit:)` 按这个键去重、保留优先级最高的变体、再截断到
  `maximumCandidates = 3`；元数据候选的 `allowsDownload` 不会被后面的变体稀释。
- 已装那一档按 identifier 排序后才进候选表，让截断作用在确定的序列上。

**反红**：去重退回按标识符 → SrtFlowCoreChecks **3 条红**，第一条就复现出
`["en_US", "en_SG", "en_IN"]`；`selectProbe` 退回「只试第一段」→ ProjectFile
**9 条红**（含真实媒体那 4 条）；`soundClips` 退回 info 判据 → **1 条红**；
吞掉 `InfrastructureError` → **1 条红**；`TranslationPreflight` 自己再实现一套 /
已装档不排序 → 接线守卫红。

**一次没抓到的冒烟（记下来，别当它验过）**：为了在真窗口里复现「第一段没有
音轨」，用 ffmpeg 造了「无音轨 mp4（主轨）+ 纯音调 m4a（音频轨）」的工程跑
Auto-detect，结果是
「Couldn't confidently detect the spoken language.」 —— 看起来像修好了。
**把两处修复撤掉重编再跑，输出一模一样。** 原因：导入时 `MediaProbe` 会把
`info.hasAudio` 填成 false，旧的 `if let info, !info.hasAudio` 过滤器**同样**
会把这段排除掉。真正会踩到旧代码的是 `info == nil`（宽容解码的老工程、探测还
没回来的导入中素材）和「info 说有音轨、实际抽不出来」（损坏文件）这两种，
而它们都不好在冒烟里稳定制造。所以这条回归**只由自检覆盖** —— 真实媒体那组
直接构造 `SoundClip`，绕开 `MediaProbe`，正好命中旧代码。
**「反证没抓到」本身就是发现**（2026-08-07 教训的复用）：一条不能区分修复
前后的冒烟，不是证据。

**教训**：
- **便宜的预筛不能当判据。** `fileExists` 只配用来省一次 I/O，
  「能不能用」必须由真正的那次操作回答（同 2026-08-07「『有没有 X』不能用
  『能不能解析 X』代替」的反面）。
- **冒烟也要做反证。** 撤掉修复重跑一遍，输出不变的冒烟等于没跑 ——
  跟守卫必须先红过是同一条纪律。
- **假素材测不出真解码。** 守卫里用重复字节凑出来的文件，覆盖的是路径逻辑，
  不是媒体逻辑；涉及「素材可不可读」的合同必须有真实媒体。
- **上一轮的观察要反推到实现上。** 「同语言变体的置信度差是噪声」这句话第一轮
  就写进案例了，却没人回去问「那去重键为什么还是完整标识符」。
- **抽出共享合同的那一次，最容易在自己新写的分支上再分叉一遍。**

## 第三轮复审一连（第二轮修复自身的缺口）

### 七、[P2] 取消被跳过逻辑洗成「素材不可读」

**症状**：Auto-detect 期间按 Stop，任务终态是
`.failed("None of the audio sources could be read…")` 而不是 `.cancelled` ——
用户被告知素材有问题，其实是他自己取消的。

**根因**：第二轮加的 `selectProbe` 只在**抽取器主动抛 `CancellationError`** 时
才停。`AudioWindowReader` 对无音轨素材在检查取消**之前**就抛 `ReadError`，
于是取消期间剩下的候选各抛一个 `ReadError`、全被跳过逻辑吞掉，一路走到
`return nil`；调用方 `guard let probe else { throw TaskError(...) }` 又在查
token **之前**，nil 就被翻成了失败文案。

**跳过逻辑天生会吃错误，所以它必须先把取消问清楚** —— 这是 2026-08-06
「catch 面 = 责任面」的下一层：责任面对了，但**取消这条正交的通道**没有在
吞错误的那一刻被排除。

**修复**：`selectProbe` 三个点都查取消（每轮开头 / 吞错误之前 / **返回 nil
之前**），两条通道都问（注入的 `isCancelled`（生产是 `token.isCancelled`）+
结构化的 `Task.checkCancellation()`）。**返回 nil 之前那一处是关键**：它把
nil 的含义收窄成「确实全都读不出音频」，调用方的 nil→失败文案转换就再也不会
冤枉取消 —— 顺序错误被结构消掉，而不是靠调用方记得先查。调用方仍加了一道
token 复核（每个 await 前后都要问）。

**反红**：三处全撤（= 修复前的行为）→ ProjectFile **6 条红**（两条取消通道各
「归错错误类型」+「多试了 2 段」，加最后一段那两条）；只撤「吞错误前查」+
「返回 nil 前查」→ **2 条红**；只撤「每轮开头查」→ **2 条红**（进门已取消时
不该发起任何抽取）。三处各自都是承重的。

**教训**：
- **「跳过某类错误」的逻辑必须先排除取消。** 取消和「这一项失败了」是正交的
  两件事，而跳过逻辑会把二者压成同一个分支。
- **让哨兵值自带含义收窄。** `nil` 从「没找到」收窄成「确实全都读不出音频」
  之后，调用方怎么翻译都不会错 —— 比在调用方补一句「先查取消」可靠，因为
  下一个调用方不会记得。

## 教训 / 防回归

1. **同一个坑第二次踩，说明防线建在了注释上。** 2026-08-04 已经写过「加字段
   必须升版本」，这次照样漏 —— 因为唯一的守卫是一条自反断言。**版本号这类
   「必须随改动同步变化」的常量，断言里要写死外部真值**，拿常量跟自己比等于
   没写。
2. **阈值必须由数据反推，并且把数据本身钉成断言。** 「0.45 只兜极端场景」是
   拍脑袋，同一份实测里错误模型就在它之上。修法不只是换个数，而是把
   (0.74, 0.91) 这个判别区间写成两条 check —— 下一个人调参时会被区间挡住，
   而不是被一句注释劝住。
3. **「没得挑」不是「挑对了」。** 单候选直接采用、无置信度按中性计，两处都是
   把「零证据」当成了「弱证据」。涉及会整轨生效的自动判定，默认结局必须是
   失败 + 引导手选。
4. **合同要靠类型强制，不靠调用方自觉。** 三处修法同一形状：删掉
   `detectSourceLocale` 的 `state:` 参数、`EditSelection` 字段全
   `private(set)`、可听快照只有一个具名产地。**能让错误写法编不过，就别写在
   注释里。**
5. **纯函数写对 ≠ 被接上。** 自检编不动的 App 类型，接线用扫描守卫补 ——
   一条 grep 比再评审一轮便宜（2026-08-07 Phase 2–4 教训的复用）。
