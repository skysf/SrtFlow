# 定格（Freeze Frame）的长期约束

工具栏的雪花按钮 / ⇧⌘F：把播放头下那一帧抽成 PNG，在播放头处切开原段，
图片作为一段静止画面插进中间，后面的内容顺推。

代码：`Sources/SrtFlow/VideoEditFreezeFrame.swift`（流程与 IO）、
`Sources/SrtFlow/VideoEditTimelineEdits.swift`（纯值变换）。

## 1. 走图片素材的老管线，不写合成器

定格段 = 一个普通的**图片段**：`stillImageURL` 指向抽出来的 PNG，`sourceURL`
指向 `StillImageClipFactory` 生成的静帧循环视频。于是转场、变速、画中画、
关键帧、导出全都天生支持，一处特判都不用加。

**别为定格另起一条渲染路径。** 真要加什么，先想清楚为什么图片段不够用。

## 2. 提交模型：转码成功后一次性提交（和图片导入相反）

图片导入是「占位块先上轨、后台转完再替换」。定格**刻意不抄这个**，原因有三：

1. 转码失败时图片导入会用**第二次** `perform` 删掉占位块
   （`VideoEditProject.addImages` 的 catch），撤销栈上留下两条记录，
   用户按一次 ⌘Z 只撤回一半；
2. 占位块在预览里是被跳过的，中间会黑掉 1~2 秒；
3. 异步窗口里目标段可能被拖走/裁掉/改速，占位块已经插进去了没法回头。

所以定格是事务式的：**抽帧 → 写 PNG → 转码 → 探测 → CAS → 一次 `perform`**。
全绿才动时间线，于是定格段创建即完整（`needsStillConversion` 全程为 false），
撤销/重做严格一步，不需要任何回滚合同。

配套的两条硬要求，改这块时不能丢：

- **CAS**：入口抓 `FreezeRequest` 快照（clip id / **track** / sourceURL /
  sourceStart / sourceDuration / speed / timelineStart / 切点 / 工程代号），
  提交前逐字段核对。对不上就整单作废 —— 这一帧对应的时间线位置已经不成立了，
  插错地方比不插更糟。
- **CAS 要把准入条件整个重跑一遍**（`isFreezeEligible`），不能只比源范围：
  从主轨挪到画中画会保持同样的起点和源范围却走完全不同的 ripple 语义；
  中途给这一段加转场则会让声画永久错开（见 §4a）；轨被藏起来同理。
- **`committed` 以时间线里真有这一段为准**（`state.clip(with: freeze.id) != nil`），
  不能因为调过 `perform` 就当成功。`perform` 在「无变化」时会直接返回，
  `insertFreeze` 自己也有前置条件；无脑置 true 会既留下孤儿 PNG 又对用户报成功。
- **单飞**：`VideoEditProject.isFreezing` 期间按钮置灰，连按 ⇧⌘F 不产生并发。

## 2a. 准入条件（`isFreezeEligible`，入口和 CAS 各跑一次）

不给定格的情形，每条都有硬理由：

| 情形 | 理由 |
|---|---|
| 纯音频段 / 图片段 / 还在转静帧的占位段 | 没有「这一帧」 |
| 多选且播放头穿过不止一段 | 不猜是哪一段 |
| 所在轨被藏起来 | 隐藏轨在预览和导出里都当不存在 |
| **主轨上牵扯转场的段**（自己往后叠或被前一段叠上来） | 见 §4a |
| 播放头落在主轨叠化区里 | 那一帧画面是两段合成的，从单个源素材抽帧必然对不上 |

## 3. PNG 的归属

- 存在**工程文件所在文件夹**；工程还没存过就落 **Downloads**。
- **不能放缓存目录**：那里的东西随时会被系统清掉，而这张 PNG 是工程唯一的
  事实来源（静帧 mp4 只是它的缓存产物）。清没了的话工程再打开会要求用户
  重链接一张他从来没见过的图。
- 失败/取消/CAS 拒绝产生的 PNG **必须删掉**（还没人引用）；
  **成功提交的必须留着** —— 重做要靠它。

## 4. 波纹范围（产品拍板，别自作主张扩大）

| 轨 | 行为 |
|---|---|
| 目标所在轨 | 切口右边整体右移，定格段填进空档 |
| 音频轨 | **仅当目标在主轨时**跟着让位；跨切口的音频段先切开再推右半 |
| 画中画 | 不动（主轨定格不推画中画） |
| 字幕、形状标注 | 不动 |

主轨定格 = 一次真正的插入编辑，所以声音要跟着走，否则切口之后的声音会比画面
早一整个定格时长。画中画上的定格只动那一条轨 —— 一个小窗的定格不该把整条节目
的声音推走。字幕不动是明确决定：那是链接进来的字幕文件，改它等于改那份 SRT。

## 4a. 为什么牵扯转场的主轨段不给定格

转场时长有个「不超过两边任一段 45%」的上限（`TimelineState.transitionOverlap`）。
定格把目标切短之后那个上限会跟着缩，于是 `packMain()` 让后面的画面移动的距离
**不等于**定格时长，而音频只会老老实实顺推一个定格时长 —— 从切口往后声画就
永久错开了。

实测（`checks/FreezeFrame` 钉住）：A 在 10s 结束、与 B 有 1s 转场，在 A 的 8.5s
定格 → 画面位移 **2.325s**、音频位移 **2.0s**，错位 **0.325s**。

要真正支持，就得按重排后的实际时间映射去推音频：每条转场缩多少各不相同，
连定格段自己的落点都会变（前一段的转场上限也会因为左半变短而缩）。复杂度
远超这个功能该有的分量，所以先用 `participatesInMainTransition` 禁掉。

⚠️ 顺带一提：**现有的 ⌘B 分割本身也有这个长度重算行为**，只是它不推音频，
所以没有「承诺了同步却做不到」的问题。哪天要给分割加音频波纹，先回来读这一节。

## 4a2. 静帧转码命令：解一帧 + `loop` 复制，且只用通用 demuxer 选项

`StillImageClipFactory.conversionArguments()` 是这条命令的唯一出处（自检
`checks/StillClipEncode` 直接拿它去真跑）。两条硬约束，都是踩出来的：

1. **只解一帧，其余 119 帧用 `loop` 滤镜复制**，不许用 `-loop 1` 让 demuxer 重放
   输入。`-loop` 的语义是重放，每个输出帧都要重新解码 + 重新缩放一次 ——
   5MB 图 5s、9.5MB 图 8.8s，而产物一模一样。配套必须有 `-frames:v`
   （不是 `-t`）截断：`loop` 复制完之后会把输入剩下的帧接着往下吐，动图/多页图
   会超过 `stillDuration`。
2. **只能用所有 demuxer 都认的选项**。`-loop` / `-framerate` 是 image2 专属，
   gif（gif demuxer）和 heic（mov demuxer）会在开文件那一步就死；输入帧率用
   `-r`。tile grid 型 heic 目前仍不支持，**不许**用 `-filter_complex "[0:v]"`
   绕 —— `[0:v]` 拿到的是单块瓦片，会把大图悄悄变成 512×512。

改这条命令前读 [案例](../bugfixes/2026-08-08-still-clip-decode-per-frame.md)：
它同时记了「性能断言为什么用边际成本而不是绝对秒数/比值」。

## 4b. 分辨率政策只有一个判据

`StillImageClipFactory.needsNativeResolution(for:)` 是**两条政策之间唯一的判据**，
所有地方（生成、查缓存、重转、落地过滤）都必须用它。它成立的原因是对「源尺寸」
和「产物尺寸」给出同一个答案，于是政策能从工程文件里存着的 `info.displaySize`
唯一反推出来 —— 缓存被系统清掉后要按原政策重转，除此之外没有别的线索。

- 超过上限 → 走原生 → 产物尺寸 = 源尺寸，仍超过上限 ✓
- 不超过上限 → 走照片政策，而 `force_original_aspect_ratio=decrease` 只缩不放，
  产物 = 源，仍不超过上限 ✓

尺寸没过线时两条政策产出完全一样，那就统一走照片政策 —— 免得同一张图在两个
缓存文件之间来回横跳。

**查缓存必须显式带政策**（`cachedStillVideo(for:nativeResolution:)`）。曾经是
「两条都查、原生优先」，同一张 PNG 既被当定格素材又被用户当普通图片拖进来时会
串线：两个缓存都在就都拿原生，只剩照片缓存就把定格段悄悄降成 1080p。
同理，重转任务按 **(图, 政策)** 分组，落地时**只更新同政策的段**
（`regenerateStills`），否则后跑完的那项会把两边都改成自己的产物。

## 5. 抽帧的两条纪律

- **前后容差都必须是 `.zero`**。给了容差 AVFoundation 可以在窗口内自由取
  （通常就近拿关键帧），定出来的画面和眼睛看到的对不上。零容差失败才退回
  半帧容差，且半帧要用 **source 空间**的（`KeyframeTrack.sourceTolerance`，
  源时间比时间线时间快 `speed` 倍，这个空间陷阱见 `VideoEditAnimation.swift`）。
- **叠化区里禁用定格**（`TimelineState.isInsideMainTransition`）。转场叠化区
  显示的是两段合成出来的画面，从单个源素材抽帧必然对不上。

## 6. 有关键帧动画的段要把动画烘成静态值

定格段只有一帧，直接抄 `animation` 会让它在那 2 秒里继续飘、接缝处跳一下。
`EditClip.makeFreezeClip` 用 `animatedPlacement` / `animatedRotation` /
`animatedOpacity` 取那一刻的值写进静态字段，`animation` 置 nil。

其余静态变换（placement / crop / rotation / flip / opacity / overlay*）一律照抄
—— PNG 是**未裁剪的原始帧**，继承 crop 之后画面才对得上。

## 7. 纯值变换要留在 `VideoEditTimelineEdits.swift`

`split` / `insertFreeze` / `isInsideMainTransition` / `makeFreezeClip` 都不碰
AVFoundation、ffmpeg、磁盘、UI。这不是洁癖：`scripts/check-freeze-frame.sh`
是**直接挑源文件编**的（SwiftPM 不允许两个 target 共用源文件），一旦把它们挪回
`VideoEditProject.swift`，就会拖进 AppKit/SwiftUI/AVFoundation 整个 App，
自检立刻编不过。

## 7a. 待办：切工程的取消停不掉抽帧/ffmpeg

`invalidateDocumentGeneration()` 会 `cancel()` 掉任务，但**取消传不进去**：

- 抽帧的 catch 会把「取消」也当成零容差失败，接着用半帧容差**再取一次**
  （`VideoEditFreezeFrame.extractFrame`）；
- 静帧转码的 `Process` 没挂 cancellation handler
  （`StillImageClipFactory.run`），会一路跑完。

代数守卫保证了旧任务不会污染新工程，PNG 最终也会被清理，所以**不是数据正确性
问题**。症状是：旧任务跑完之前，新工程的定格按钮和「导入中」转圈还卡着，
缓存里还会多一个没人引用的 mp4。

现在转码不到 1 秒，先不做。真要修：`extractFrame` 的 catch 里先
`try Task.checkCancellation()`，`run` 改成 `withTaskCancellationHandler`
+ `process.terminate()`。

- **牵扯转场的主轨段定格按钮是灰的**（理由见 §4a）。想定格就先把那条转场去掉。
- 升级到带 `-framerate` 修复的版本后，缓存目录里旧的 `-v2.mp4` 会变成孤儿
  （照片政策已升到 `-v3`）。不主动清：那是 `~/Library/Caches`，系统会回收。
- 工程另存到别的文件夹后，老的定格 PNG 不跟着搬；文件还在原处就能正常打开，
  被挪走才触发现有的重链接提示。
- 未保存工程时 PNG 落 Downloads，之后保存工程也不会把它搬过去。
- 定格段最长 60 秒（`StillImageClipFactory.stillDuration`）。
- **HDR 素材的定格帧是 SDR**：整条静帧管线就是 SDR（yuv420p、无 HDR 元数据），
  `dynamicRangePolicy = .forceSDR` 只是把这件事写死成可预期的那一种。
