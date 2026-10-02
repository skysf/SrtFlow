# 视频 upscale：轨道上的片段送 fal 放大、比过再换

> 2026-10-02 起。方案和用户拍的板在 [视频 upscale](../plans/2026-10-02-video-upscale.md)，实测数字在 [smoke test](../reports/2026-10-02-upscale-smoke-test.md)，
> fal 那一层（档位、估价、上传、账单）在 [fal.ai 生成](fal-generation.md) 第十二节，换源的规则在
> [工程文件与素材重链接](video-edit-project-file.md)「四之五」。本文记任务那一层（`Sources/SrtFlow/Upscale/`）的长期约束；
> 改 `UpscaleRange` / `UpscaleSourceTrimmer` / `UpscaleAudioMux` / `UpscaleOutputName` / `UpscalePipeline` / `UpscaleJob` 之前必读。

## 一、一次 upscale 是什么

用户在检查器或右键菜单里对一段画面点「Upscale…」，面板上选范围、目标分辨率、档位，看到估价，点「开始」；
App 把原片的那一段裁出来送 fal，做完**先弹对比窗口**，用户点「替换」才换源（方案第 15 条），文件已经存在原片旁边。

| 环节 | 谁 | 规矩 |
| --- | --- | --- |
| 范围 | `UpscaleRange`（纯值） | 三选一：这一段 / 工程里用这个原片最长的那处（默认）/ 整个文件。前两种两头各留 **1 秒余料**（主轨转场最多借 2 秒，往外拖一点也要有帧），起点往前对到整帧、终点往后对到整帧，夹在文件两头之内。范围盖住的用处（差一帧以内算盖住）就是做完要换的段；盖不住的不换。点开的这一段比别处短时，面板提示「另一处用了更长的范围」、建议直接做那一处（方案第 5 条）。变速的段按**源秒数**算范围和钱 |
| 输入 | `UpscalePipeline.uploadsWholeFile` / `UpscaleSourceTrimmer` | 范围就是整个文件、原片是 mp4、没超过模型的时长 / 大小上限：原片直接上传。否则裁一份：AVAssetReader → AVAssetWriter，原分辨率、原帧率、H.264、**只有画面**，码率每像素每帧 0.3 bit、6–20 Mbps（20 秒 × 20 Mbps = FLUX 的 50 MB 上限）。阻塞的读和编只在 `MediaReadQueue.export` 上（[阻塞的媒体读取](blocking-media-reads.md)）；Task 取消时经 `UpscaleCancelFlag` 停下、不留半个文件。裁出来的文件自己的 0 秒 = 原片的范围起点，这个数就是记录里的 `sourceOffset` |
| 送 fal | `FalClient.upload` → `FalUpscaleTier.body` → `FalClient.run` → `download` | 上传走 `fal-cdn-v3`（[fal.ai 生成](fal-generation.md) 第十二节）；请求体按档位；最多等 25 分钟；Task 取消时替 fal 也取消 |
| 声音 | `UpscaleAudioMux` | **fal 给的声音一律不要**（实测只有 FLUX 原样复制，Topaz 裁到画面长度、字节重采样、Bria 重编码且短 0.1 秒）：用 App 自带的 ffmpeg 把原片 `[sourceOffset, +时长)` 的声音封回去 —— 画面流原样复制（**HEVC 要点名 `hvc1`**，不然 AVFoundation 不认）、声音从原片解码后精确裁、重编 AAC 256k（流复制只能在 AAC 帧边界上切，差 ±20 ms）、`-shortest` 按画面收尾。原片没声音就不封。ffmpeg 不在时文件照落、`audioRestored` 为假 |
| 落盘 | `UpscaleOutputName` | `<原名>_<宽x高>_<档位>.mp4`，宽高是**探测出来的输出尺寸**（FLUX 最小 1.5 倍、Topaz 最多 4 倍，和目标不一定一样）；放原片的文件夹，写不进去退到工程的家、再退到下载；撞名加编号（`ExportFileName.unoccupied`，全 App 一个规矩，不覆盖） |
| 结果 | `UpscaleOutcome` | 文件、探测信息、`ClipUpscaleRecord`（原片、偏移、档位、原片的探测信息）、fal 的请求号、耗时。换源时拼成 `ClipSourceSwap.Replacement` 交给 `VideoEditProject.applyUpscale` |
| 账 | `UpscaleJob` | 面板上的估价就是用户的确认（方案第 10 条）：开跑先把估算记进 fal 的账本，不再问；没做出来（失败 / 取消）退回，拿到结果就不退。做完每 30 秒问一次账单明细、最多六次，查到实际扣费就把账本里的估算换成实收、记进结果（要 ADMIN 权限的 Key；查不到只有估价） |
| Key | `UpscaleJob` | `FalKeyCache.shared.key(willAsk:)`：新版本第一次读会弹 macOS 的授权框，`keyPrompt` 让界面提醒用户点「始终允许」 |
| 进度 | `UpscaleJob.state` / `UpscaleActivity.shared` | 阶段（`FalJobPhase`，[fal.ai 生成](fal-generation.md) 第十三节）：裁 → 上传（字节比例，1% 一格）→ 排队（带位置）→ 处理（这一阶段过了多久 + 这一档通常几分钟 `FalUpscaleTier.typicalSeconds`）→ 下载（字节比例）→ 封声落盘。同一阶段同一比例只报一次；换阶段才重记开始时刻（`FalJobProgress`）。界面从 `UpscaleActivity` 读：检查器那一节和编辑器顶上的状态行（`FalStatusRows`）同一份文字；切工程 `cancelAll` |

## 二、硬约束

1. **做完不替换**：对比窗口里用户点了替换才 `applyUpscale`；换的时候重新算一遍工程里用这个原片的段（`clipIDs(usingPicture:)`），范围被盖住的才换。
2. **范围按原片算**：在 upscale 过的段上再做，输入仍是原片（`ClipUpscaleRecord.originalURL`），`sourceOffset` 永远相对原片。
3. **估价按夹过的输出尺寸、按送去的秒数**（含余料）：`UpscaleRequest.estimate` = 档位 × `range.duration` × 输出面积规则，和面板上显示的是同一个数。
4. **一次只用一个 fal 请求**：一段一次；多选第一版不做（方案第 12 条）。
5. **中间文件只在 `UpscaleJob.workFolder`**（临时目录），每次做完 / 取消 / 失败都删干净；成品只在原片旁边（或退路）。
6. **不弹模态框、不进撤销分组**：任务本身不改工程；换源那一步是一次 `perform`。

## 三、界面（2026-10-02 第四刀，mockup 定的样子）

| 哪里 | 文件 | 规矩 |
| --- | --- | --- |
| 检查器一节 | `VideoEditInspector+Upscale.swift`（检查器的一段 body）+ `Upscale/UpscaleJobStatusView.swift` | 画面段才有，放在头部信息下面、Speed 上面。三个状态：还没做（一句说明 + Upscale…）、做着（`UpscaleJobStatusView` **只订阅那一个任务**：阶段、估价、取消、钥匙串授权的提醒）、做完还没处理（Compare… / Discard）、已换源（档位、日期、扣费、原片在哪、Compare… / Revert to Original）。**不是单独的视图**：预览性能 ratchet 数的是 body 次数，选一段多一个视图就是多一次（CI 2026-10-02 逮到 +1 body、+1 update）；任务的增删由检查器上的 `upscaleActivity` 订阅（很少变）；「Upscale…」不挂提示（提示是一层 NSViewRepresentable，每选一段多一次 update） |
| 右键菜单 | `VideoEditTimelineClipBlock.swift` | 图片段没有；普通块一项 Upscale…；换过源的块三项 Compare with Original… / Revert to Original Clip / Upscale Again…。**块不做 IO**：换回原片找不到文件时用 `project.notice` 说一句，菜单不灰 |
| 块角标 | 同上 | 换过源的块名字旁一枚短边的标（`1080p`），和静音图标同一处，不盖缩略图 |
| 面板 | `Upscale/UpscalePanel.swift` + `UpscalePanelModel.swift` | sheet（套 `.appLanguage()`）。范围三选一（默认：别处用得更长就选最长的那处，否则这一段；有另一处更长就提示）、目标三档（默认按画布短边能到的那档，比画布大提示画布也要改）、六个档位各一行（一句话、大约几分钟、夹过的输出尺寸、估价；超过模型的时长 / 大小上限灰掉）、文件名预览、今天已花 / 上限（超限只标红）、没有 Key 才拦。点开始：`UpscaleJob` 进 `UpscaleActivity` |
| 摆出来 | `Upscale/UpscalePresenter.swift` | 挂在检查器底下的不画东西的小视图，只订阅 `UpscaleActivity.panel` / `.compare`；右键、检查器、做完的任务都往那两个字段里写。`Equatable`（按工程的身份）+ `.equatable()`：检查器每重算一次不重算它 |
| 对比窗口 | `Upscale/UpscaleCompareView.swift` + `UpscaleCompareStage.swift` + `UpscaleComparePlayback.swift` | 做完先弹（已经在看别的就不抢）。两个 AVPlayer 同一个主机时间起步（`setRate(_:time:atHostTime:)`，不读 `currentTime`），原片出声、upscale 文件静音，原片加 `sourceOffset`。分割线（点哪儿到哪儿、能拖、底下有滑杆）/ 并排；缩放 适合 / 100% / 200%（按 upscale 文件的像素，默认 100%：缩到窗口大小看不出差别），滚轮平移。按钮：Replace Clip（`applyUpscale`，工程里用这个原片且范围被盖住的段一起换，一步撤销）/ Keep Original（文件留着）/ Try Another Model…（回面板）；看已换源的段时是 Revert to Original / Close。实际扣费那一行单独订阅任务（账单几分钟后才有） |
| 状态行 | `Fal/FalStatusRows.swift`（`UpscaleStatusRow`） | 编辑器顶上、「AI 正在剪辑」那条横幅底下，每个任务一行（mockup「Status row while upscaling」）：「Upscaling <段> with <档位>」、四个阶段的小标（过了的打勾、当前的带百分比 / 已用时间 / 通常约几分钟）、估价、Stop；做完：「<段> upscaled to 1920×1080 · est. / charged」+ Compare… / Dismiss；失败 / 取消一句 + Dismiss。不选中那一段也看得见（检查器那一节只有选中时才有）。只订阅 `UpscaleActivity`，没任务不画 |
| 切工程 | `VideoEditProjectDocument.closeCurrentDocument` | `UpscaleActivity.cancelAll()`：在飞的作废（替 fal 也取消），做完的文件留在磁盘上 |

还没做的：导出面板的「有几段低于目标分辨率」提示（mockup 第二排）；画布自定义尺寸；AI 工具（清单预算只剩 53 字）；多选；
Topaz 的 unit 台阶（要摸准再跑 10 / 12 / 15 秒各一条）。

## 四、回归

- `scripts/check-upscale.sh`（`check-all` 第 2 组，要 ffmpeg 造带声音的素材）：范围（三选一、余料、对齐、夹住、谁被盖住、提示）、起名落盘、
  封回原声的参数（精确裁、画面复制、hvc1）、真裁一段（帧数 / 时长 / 尺寸、首帧是原片那一刻、没声音、能取消）、流水线对着假 fal 走全程
  （裁 → 上传 → 提交 → 排队 / 处理 → 下载 → 封声 → 落盘；整个 mp4 直接上传、超过模型上限还是裁、取消替 fal 也取消且不留文件、fal 拒绝就没有文件）。
  阶段按顺序、上传 / 下载的比例只升不降且报到 100%、同一阶段同一比例只报一次（2026-10-02 进度那一刀）。
  反向验证：去掉 hvc1 的点名、把 `-ss` 挪到原片的 `-i` 之后、阶段重复报、整文件判定不看时长上限，各红。
- `scripts/check-fal.sh` 第七 / 八组（档位、估价、上传、账单）；`scripts/check-project-file.sh` 第 41 组（换源）。
- `checks/fal-wiring.sh`：用 Key 的只有生成任务、配旁白、upscale 任务三处。
- 界面这一层自动化够不着（真窗口、两个播放器、分割线手感），走人工回归；扫描守卫钉着：sheet 套 `.appLanguage()`、提示走 `.instantHelp`、
  每个视图 body 计数、文案三张表配齐、用 Key 的只有三处。
- **人工回归**（发版前、拿真 Key）：
  1. 选一段 720p 的画面段：检查器头部下面有「Upscale」一节，一句说明 + Upscale…；音频段、图片段没有这一节；右键菜单有 Upscale…。
  2. 点开面板：默认范围（工程里另一处用得更长时选最长的那处并有提示）、默认目标按画布、六行价格随范围 / 目标变、文件名预览对；没有 Key 时按钮灰且指去设置。
  3. 点开始：检查器那一节变成阶段 + 估价 + 取消，编辑器顶上多一行状态（上传的百分比真的在走、排队位置、处理那一格每秒走、下载百分比），
     换选中别的段那一行还在；期间照常剪辑；取消后不扣钱、没有文件。
  4. 做完弹对比窗口：分割线点哪儿到哪儿、并排、100% / 200% + 滚轮平移、空格播放两边同步、声音是原片的；Keep Original 文件留着、片段不变；
     Try Another Model… 回面板；Replace Clip 之后片段指向新文件、关键帧 / 标记 / 音量曲线位置不变、块名字旁有「1080p」、⌘Z 一步撤回。
  5. 换过源的片段：检查器显示档位 / 日期 / 扣费 / 原片，Compare… 看原片 vs 现在，Revert to Original 换回；把原片挪到别的文件夹再换回也行；
     原片删了提示找不到。
  6. 账单：做完几分钟内对比窗口 / 检查器的扣费从「估」变成实收；设置 → AI 的「今天已花」跟着变。
  7. 切工程：做到一半的任务取消，不弹对比窗口。
