# 优化媒体：长 GOP 的源转成密关键帧的代理（预览的画面）

> 2026-10-01 起（V1：探、判、存、转一块；V2：builder 按段换源 + 后台转码队列 + 停着时换 + 预览工具条的「优化媒体 / 原片」；
> V3：设置里的占用 / 上限 / 清空 + 启动时后台过期 + 转不了的只在菜单里标）。改 `Sources/SrtFlow/OptimizedMedia/`、
> `CompositionClipInsert`、`MediaInfo.keyframeInterval`、`MediaReadQueue.proxy`、预览重建传 `proxies` 的那一处、
> 设置里的「优化媒体」一节之前必读。
> 方案与数字见 [方案](../plans/2026-10-01-video-optimized-media.md)；声音那一半见 [音频引擎](audio-engine.md)；
> 读采样的规矩见 [阻塞的媒体读取](blocking-media-reads.md)。

## 一、是什么

`Sources/SrtFlow/OptimizedMedia/`，每个文件一件事：

| 文件 | 管什么 |
| --- | --- |
| `MediaKeyframeProbe.swift` | 一个源的关键帧间隔：直通读前 60 秒的采样表（不解码），相邻关键帧的最大距离；全帧内 = 0。跑在 `MediaReadQueue.detail` 上 |
| `DecodeSpeedProbe.swift` | 这台机器解码多快（fps）：解 120 帧计时；按「机型 + macOS 大版本」记在 UserDefaults（`optimizedMedia.decodeFPS.<机型>.<版本>`） |
| `OptimizedMediaPolicy.swift` | 纯值：要不要转（`needsProxy`）、转多大（`targetSize`）、码率、关键帧间隔 0.5 秒、源时间 10 秒一块、一段用到哪几块（两边各留一块） |
| `OptimizedMediaStore.swift` | 缓存：`~/Library/Caches/SrtFlow/OptimizedMedia/<路径哈希>/chunk-<i>.mov` + `index.json`（身份、参数版本、每块最后用到的时间和大小）；上限（UserDefaults 里的键只有它读写；默认、下限、几档）、LRU、过期（天数 `expiryDays`）、占了多少、清空 |
| `OptimizedMediaTranscoder.swift` | 把一块转出来：`AVAssetReader` 经视频合成解（块的轨从块头盖到块尾）→ `AVAssetWriter` 硬编 H.264，落到 Store。跑在 `MediaReadQueue.proxy` 上 |
| `OptimizedMediaLookup.swift` | 纯值：builder 换源用的那张表（源 → 块号 → 块文件），一段用到的块齐不齐（`readyChunks(for:)`） |
| `OptimizedMediaPlan.swift` | 纯值：这份时间线还差哪些块、先转哪块（播放头附近的段先）、哪些源要转、哪些源还没探关键帧间隔 |
| `OptimizedMediaCoordinator.swift` | 工程上的协调者（`VideoEditProject.optimizedMedia`，`ObservableObject`，只有工具条的菜单订阅）：模式、队列、转、停着时请重建、补探、量解码速度、转不了的源（`unavailable`） |
| `OptimizedMediaCacheSettings.swift` | 设置里「优化媒体」那一节的状态（`ObservableObject`，只有那一节订阅）：占了多少（proxy 队列上算）、上限几档、清空（proxy 队列上 `removeAll` → 协调者 `reset()` → `scheduleRebuild()`） |
| `../CompositionClipInsert.swift` | builder 插画面的那一步：原片一片，或代理几块首尾相接；差一块 / 插不进去退回原片 |
| `../OptimizedMediaMenu.swift` | 预览工具条上的「优化媒体 / 原片」菜单 + 转码中的小转圈 + 转不了的小感叹号（菜单里列文件名） |
| `../OptimizedMediaSettingsSection.swift` | 设置窗口里的「优化媒体」一节：占用、「清空」、上限的几档；只订阅 `OptimizedMediaCacheSettings` |
| `../SrtFlowApp.swift` | 启动时在 proxy 队列上 `expire(olderThan: expiryDays)`（`expireOptimizedMedia`）；设置窗口里摆上那一节 |

`MediaInfo.keyframeInterval`（`MediaProbe.swift`）：导入时顺手探，随工程存；老工程没有这个键 = nil（不知道），不是 0 ——
打开时协调者补探、用 `applyDocumentRepair` 写回（不标脏）。

## 二、合同

1. **只转长 GOP 的源，按这台机器算。** `needsProxy`：一个 GOP 的帧数 ÷ 解码速度 > 两帧的时间才转
   （验收是点一下到画面 ≤ 2 帧）。全帧内（间隔 0、ProRes / MJPEG 这类编码）、静帧、没探过的（nil）、解码速度没量过的都不转。
   解码速度是量出来的，不是估的：快机器上 1 秒一个关键帧也可以不转。
2. **原分辨率，4K 减半。** 长边超过 2560 才减半（用户要看最高清）；宽高取偶数。码率按像素数等比，1080p 12 Mbps，封在 2–40 Mbps。
3. **代理是 H.264、0.5 秒一个关键帧、没有 B 帧、只有画面、旋转矩阵照抄。** 关键帧密了 seek 才快（探针：27–36 ms）；
   B 帧要等后面的帧，seek 多解一截；声音在引擎里直接读原件，代理不带。
3b. **代理经视频合成读、块的轨从块头连续盖到块尾。** 源经 `AVAssetReaderVideoCompositionOutput` 按 `frameDuration` 的格子读：
   时间范围的起点先出一帧（块头落在两帧之间 —— 29.97、录屏 —— 也是：探针里 29.97 的源从 10 秒读，第一帧 10.000、第二帧 10.010），
   之后画面变了才出一帧，静止期（变帧率的录屏几秒没有新帧）是一帧撑到下一次变化，整块都在静止期里就只有块头那一帧；写的时候
   `endSession` 落在块尾，块的轨正好盖住整块（探针：2–8 秒没有帧的源，第 0 块 120 帧、正好 10 秒；[3, 7) 这一块 1 帧、4 秒）。
   合成轨只能引用源轨范围之内的时间，块的轨不从 0 起、不到块尾，第一截 / 最后一截就插不进去。帧率照源的标称值，常见几档按精确分数（`proxyFrameDuration`，容差 0.05%：29.97 和 30
   只差 0.1%），对不上的（录屏报的是平均值）按 30。**合成输出必须 `alwaysCopiesSampleData = true`**：像素缓冲交给编码器之后
   还在它手里，不拷贝的话读取器下一帧就把那块内存回收重用，编码器在第 4、5 帧上报 kVTParameterErr（时有时无；探针 3/4 红、拷贝 0/4）。
4. **按源时间分块，一块 10 秒，一块一个文件。** 块的边界不对齐源的关键帧（解到块头的代价和 seek 一样，只付一次）；
   最后一块到源的结尾；块文件自己的时间从 0 起 = 源的 `10i` 秒。读取器按 GOP 解，块尾之外多吐的几帧要扔掉（自检钉着帧数正好）。
5. **缓存按路径找、按身份认。** 目录名是路径的哈希；索引里记完整身份（inode + 卷 + 大小 + 修改时间，同 `MediaAssetCache` 的认法）
   和参数版本。路径上换了文件、原地改写过、参数版本变了 → 整个目录作废重来；索引坏了、块文件不在了 = 没转过。
   **改任何转码参数都要 +1 `parametersVersion`**（关键帧间隔、码率、尺寸规则、编码器）。
6. **总量有上限，丢最久没用的。** 默认 10 GB（`optimizedMedia.capacityBytes`，**十进制**：1 GB = 10 亿字节，和设置里显示的、
   访达里看到的一致 —— 写成 2^30 设置里会显示「10.74 GB」）；设置里给几档（2 / 5 / 10 / 20 / 50 GB，`capacityPresets`），
   键只经 `OptimizedMediaStore` 读写（`capacityBytes(in:)` / `setCapacityBytes`），低于下限（250 MB）按下限 —— 0 会把刚转好的块
   当场丢掉，等于关掉优化媒体。每次落一块就看总量，超了按「最后用到的时间」从最早的丢（LRU）；**设置里改小上限当场
   `enforceCapacity`**（在 proxy 队列上）。30 天（`expiryDays`）没有任何工程用到的块删掉：**App 启动时在 proxy 队列上扫一遍**
   （`SrtFlowApp.expireOptimizedMedia`，和转码串着、登记成后台读，冒烟的「落定」等它）。缓存丢了就重转，不是错误。
7. **读和编都是阻塞的，只在 `MediaReadQueue` 上跑**：探在 `detail`、转在 `proxy`（utility，宽度 1 —— 解码器和编码器各只有一个，
   并行也不更快；在后台转，不和播放抢）。转码每读一帧看一眼取消标记。
8. **10-bit / HDR 的源第一版不转**（H.264 只有 8-bit，转了会灰）：`load` 报 `unsupportedSource`，照用原片。HEVC Main10 是后面一刀。
9. **成片永远用原片。** 代理只在预览合成里出现：`VideoEditCompositionBuilder.build` 只有预览重建那一处传 `proxies`
   （`VideoEditProject.scheduleRebuild`）；导出、预渲染（`VideoEditPrerender`）、AI 看（`AIFrameComposer`）、缩略图、波形都不碰缓存目录。
   守卫 `checks/optimized-media-wiring.sh` 钉着。
10. **换源只换画面，段的时间账一个数都不动。** `CompositionClipInsert`：这一段真正要插的那一截（`renderSourceStart` 起）盖住的块
   都转好了才按块插（块之间首尾相接：格子全在 600 分之一秒上算，每片的长度是边界之差，加起来正好等于插原片的长度 —— 各片
   各自截断会少一两格、接缝上露一帧黑）；差一块、哪一片插不进去（块文件被清了）就撤掉插了一半的、按原片再来。起止、变速、
   首尾定格都按段算。画面几何按插进去的那条源轨算（4K 的代理减了半，尺寸是它自己的；裁切 / 摆放都是归一化的，算出来
   的画面和原片一样）。
11. **只在停着的时候换。** 一块转好、某一段用到的块刚好齐了才请重建（没齐的块不值一次重建）；播放中等暂停
   （`clock.$isPlaying`）；块一块块到时最多隔 3 秒换一次，队列空了马上换。播放中 `replaceCurrentItem` 画面会闪一下。
12. **先转播放头附近的。** 每次重建落地之后按这份时间线算还差哪些块（`OptimizedMediaPlan.jobs`：每段按离播放头多远排，近的先；
   同一段按块号；两边各留一块余量），队列换新；路上那一块转完照收。切工程 `reset()`：路上的作废，表清空（块留在磁盘上）。
13. **一个源转不了就用原片**（编码器拒绝、10-bit / HDR）：这次运行里不再试；**只在工具条的菜单里标一下**（菜单旁一个小感叹号、
   菜单里列出文件名，`OptimizedMediaCoordinator.unavailable`），**不进提示条** —— 提示条常驻、要用户点掉，而「用原片」不需要用户做
   什么（V2 那版写 `project.notice`，每开一个带这种源的工程都弹一条）。守卫钉着协调者不许写 `notice`。
14. **「优化媒体 / 原片」记在 UserDefaults（`optimizedMedia.previewMode`），不进工程文件**；切换 = 一次重建。默认优化媒体。
   性能台架用参数域 `-optimizedMedia.previewMode original` 量原片那条路（托管 runner 没有硬件编码器的保证；换源的合成和原片同样的
   层数，结构由自检钉着）；冒烟不关，`settle` 等 `backgroundReadsInFlight` 归零 —— 转码、补探、量解码速度都登记了后台读。
15. **协调者只有工具条的小菜单订阅**（`OptimizedMediaMenu`，`ObservableObject`）；转码的进度不许叫醒整个编辑器
   （[预览性能 ratchet](preview-perf-ratchet.md) 第十节）。菜单不读工程。设置里那一节同理：只订阅 `OptimizedMediaCacheSettings`
   这个小对象，不读工程；占用在 proxy 队列上算（和转码串着，不在主线程上读索引），那一节摆着时每隔几秒算一遍。
16. **清空之后要让当前工程作废再重建**（`OptimizedMediaCacheSettings.clear`，唯一能调 `removeAll` 的地方）：先 `reset()` 取消路上
   的那一块（不然 `removeAll` 在 proxy 队列上排在它后面、转好的还会落进刚清空的目录），proxy 队列上 `removeAll()`，然后
   **紧跟 `optimizedMedia.reset()` 再 `scheduleRebuild()`**。为什么：协调者内存里那张「转好的块」表还指着删掉的文件 ——
   builder 插不进去会退回原片（不黑），但表上写着「齐了」，`sync` 就不会再把这些块排进转码队列，优化媒体从此不回来；
   作废表、重建一次，重建落地的 `sync` 重新排队、后台重转。清空不弹模态框：按钮旁一行字说「已清空，预览用原片，后台重新准备」。
   协调者 `sync` 扫索引时**文件也在才算**（同 Store 的认法）：启动时的过期扫描、设置里的清空都可能刚删掉某块。

## 三、还没做的

- HEVC Main10 的代理（HDR 源）；加 / 去掉场景那类只换声音的改动不该触发换源的重建（现在走整条重建，和以前一样）。
- 设置里的占用是按索引算的（`totalBytes`），转码落盘之前的临时文件、索引坏了的目录不算在内；想看真实的磁盘占用去访达。

## 四、回归

`scripts/check-optimized-media.sh`（`scripts/check-all.sh` 第 2 组；素材是 AVAssetWriter 现写的从黑到白的渐变灰视频，不依赖 ffmpeg）：

1. 判据：10 秒一个关键帧 500 fps 要转、0.5 秒的不转、同一个源慢机器转 / 快机器不转、nil / 0 / ProRes / 静帧 / 解码速度 0 不转；
   尺寸（1080p 不动、4K 减半、竖屏不动、取偶数）、码率（1080p 12 Mbps、720p 等比、小图封 2 Mbps）、分块（10 秒一块、两边留一块、
   不超过最后一块）。
2. 关键帧间隔：8 秒一个关键帧的源量到 ≥ 2 秒、全帧内 0、读不出的 nil；`MediaProbe` 带进 `MediaInfo`、存盘往返、老工程缺键是 nil。
3. 解码速度：量到远大于实时的正数；记忆的键带机型 + 版本；记住的读得回来。
4. 真转一块：0.5 秒内必有关键帧、没有 B 帧（解码时间戳 = 显示时间戳）、300 帧正好（块尾之外的不要）、尺寸和旋转矩阵同源、
   10 秒正好、不带声音、0.5 秒和 9.5 秒处的画面和源一样；最后一块到源结尾（12 秒的源第 1 块 2 秒）；源结尾之外的块报错；
   取消标记一亮就停、不碰已有的块。
4b. 变帧率的源（每帧往后挪 1/60 秒、2–8 秒没有帧）：第 0 块的轨从 0 起、正好 10 秒、120 帧（静止期一帧撑住）、静止期里的画面是
   停住前的最后一帧、块尾的画面对；第 1 块到源结尾（2 + 1/60 秒）、61 帧。整块都在静止期里（25 秒的源 2–22 秒没有帧，第 1 块）：
   1 帧、正好 10 秒、画面是停住前那一帧。29.97 fps 的源（帧在 k × 1001/30000 上）：第 1 块从 0 起、到源结尾、60 帧。
5. 缓存：另一个路径是另一份；原地改写（大小变）→ 旧块不算数、目录删掉；参数版本对不上 → 当没转过；索引坏了当没转过；
   三块 3 MB 上限 2.5 MB → 最久没用的丢；刚用过的留下；31 天没用的删、空目录删。
5b. V3：上限没设过是默认 10 GB（十进制）、设了读得回来、设得低于下限 / 别处直接写 0 都按下限；几档含默认、从小到大、都不低于下限；
   过期的天数是 30；清空之后总量 0、根目录没了、块查不到、再落一块照样进得去（目录重建、索引重写）；按 `expiryDays` 过期：
   29 天的留着、31 天的删。

`scripts/check-preview-composition.sh` 第 0d 组「按块换源」（`checks/PreviewComposition/ProxySwap.swift`）：段跨两块 → 合成里按块插两段、
总长和插原片一样、同样的层数、四个时刻的画面同原片；块没齐 → 插原片；不传 proxies → 原片；只用最后一块的段；变速 2×；上层轨摆小了放角上；
长边 2600 的源减半成 1300×100 之后画面同原片（摆错了会多出黑边）；块文件被清了 → 退回原片；`OptimizedMediaPlan` 的顺序
（播放头在哪段先转哪段的块、转好的不排、转不了的源不排、快机器不排）、缺探的源、纯音频不算画面。

`checks/optimized-media-wiring.sh`（第 1 组）：换源只在预览重建、成片 / 预渲染 / AI 看永远原片、builder 两处都走 `CompositionClipInsert`、
几何按插进去的源轨算、转码在 proxy 队列并登记后台读、写索引不在主线程、停着才换、切工程作废、转码参数、菜单不读工程、性能台架量原片；
V3：清空在 proxy 队列上且**紧跟 `reset()` + `scheduleRebuild()`**、`removeAll` 只许设置那一节的模型调、改上限经 Store 写并立刻
`enforceCapacity`、占用在 proxy 队列上算、缓存目录的路径和上限的键只在 Store 里出现、设置那一节不碰 `FileManager` / `UserDefaults` /
工程、设置窗口里有这一节、启动时在 proxy 队列上 `expire(olderThan: expiryDays)` 并登记后台读、协调者不许写 `notice`、
转不了的记在 `unavailable` 且菜单列出来。

反向验证（2026-10-01）：转码不设关键帧间隔 → 第 4 组「0.5 秒内必有关键帧」红；判据不看解码速度（只按 GOP 帧数定一个阈值）→
第 1 组「慢机器要转」红；V2：`CompositionClipInsert.append` 每片按自己的秒数各自截断 → 格子加起来少一格、`append` 判没插够、
退回原片 → 「零头的段也按块插两段」红（兜底没让它露一帧黑，但换源没成）；转码不把 `endSession` 落在块尾 → 4c「整块都在静止期里的
第 1 块正好 10 秒」和 4b「第 1 块到源结尾」红；builder 的几何按原片算 → 「4K 减半」的亮度红。（第一版的反向验证挑的样本不对：
段的边界都在整秒上、各片各自截断不丢格子，一直绿 —— 零头才露馅。）

反向验证（V3，2026-10-01）：见下文「V3 的反向验证」。

人工回归（发版前实机，南极工程：录屏 + AI 短片，全是长 GOP）：

- [ ] 打开工程：工具条菜单显示「优化」、右边小转圈转着；等转圈停了，播放中点时间线各处，画面当场到（≤ 2 帧，对比「原片」模式）。
- [ ] 转码期间播放：画面不闪、不卡；暂停之后才换源（暂停那一下最多闪一次）。
- [ ] 菜单切到「原片」再切回：各重建一次，画面一样；切换记住（重开 App 还在）。
- [ ] 一段 4K / Retina 录屏（长边 > 2560）：预览里看不出减半；裁切、摆放、关键帧动画和「原片」模式一样。
- [ ] 变帧率的录屏（静止期长）：静止期画面停住、不黑、不跳。
- [ ] 转场（叠化 / 推移 / 擦除）、首尾定格、变速的段：和「原片」模式逐帧一样。
- [ ] 清掉 `~/Library/Caches/SrtFlow/OptimizedMedia/` 再播：用原片、不黑；后台重转。
- [ ] 设置 → 优化媒体：占用和访达里那个目录的大小对得上（十进制 GB）；工程开着、转码转着时数字跟着涨。
- [ ] 设置里点「清空」（工程开着、停着）：按钮旁出一行字、不弹框；占用回到 0；预览不黑（用原片）；工具条的转圈重新转起来、
      转完画面又换回优化媒体（`OptimizedMedia/` 目录重新长出来）。播放中点「清空」：暂停之后才换源。
- [ ] 设置里把上限改小到低于当前占用：占用当场降到上限以下；改回去不会把删掉的块变回来（后台重转）。
- [ ] 一段转不了的源（HDR / 10-bit）：提示条不出字；工具条菜单旁有小感叹号，菜单里列着文件名；切工程之后没了。
- [ ] 导出的成片、AI `look` 的图：和以前一样（原片），`~/Library/Caches` 里没有被它们读。
