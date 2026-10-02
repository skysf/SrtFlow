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
| 进度 | `UpscaleJob.state` / `UpscaleActivity.shared` | 阶段：裁 → 上传 → 排队（带位置）→ 处理 → 下载 → 封声落盘。同一个阶段只报一次。界面从 `UpscaleActivity` 读；切工程 `cancelAll` |

## 二、硬约束

1. **做完不替换**：对比窗口里用户点了替换才 `applyUpscale`；换的时候重新算一遍工程里用这个原片的段（`clipIDs(usingPicture:)`），范围被盖住的才换。
2. **范围按原片算**：在 upscale 过的段上再做，输入仍是原片（`ClipUpscaleRecord.originalURL`），`sourceOffset` 永远相对原片。
3. **估价按夹过的输出尺寸、按送去的秒数**（含余料）：`UpscaleRequest.estimate` = 档位 × `range.duration` × 输出面积规则，和面板上显示的是同一个数。
4. **一次只用一个 fal 请求**：一段一次；多选第一版不做（方案第 12 条）。
5. **中间文件只在 `UpscaleJob.workFolder`**（临时目录），每次做完 / 取消 / 失败都删干净；成品只在原片旁边（或退路）。
6. **不弹模态框、不进撤销分组**：任务本身不改工程；换源那一步是一次 `perform`。

## 三、还没做的

界面（第四刀：检查器一节、右键菜单、面板、对比窗口、导出提示、块角标、三张语言表）；AI 工具（清单预算只剩 53 字，第一版不开）；
多选；Topaz 的 unit 台阶（要摸准再跑 10 / 12 / 15 秒各一条）。

## 四、回归

- `scripts/check-upscale.sh`（`check-all` 第 2 组，要 ffmpeg 造带声音的素材）：范围（三选一、余料、对齐、夹住、谁被盖住、提示）、起名落盘、
  封回原声的参数（精确裁、画面复制、hvc1）、真裁一段（帧数 / 时长 / 尺寸、首帧是原片那一刻、没声音、能取消）、流水线对着假 fal 走全程
  （裁 → 上传 → 提交 → 排队 / 处理 → 下载 → 封声 → 落盘；整个 mp4 直接上传、超过模型上限还是裁、取消替 fal 也取消且不留文件、fal 拒绝就没有文件）。
  反向验证：去掉 hvc1 的点名、把 `-ss` 挪到原片的 `-i` 之后、阶段重复报、整文件判定不看时长上限，各红。
- `scripts/check-fal.sh` 第七 / 八组（档位、估价、上传、账单）；`scripts/check-project-file.sh` 第 41 组（换源）。
- `checks/fal-wiring.sh`：用 Key 的只有生成任务、配旁白、upscale 任务三处。
- **人工回归**（发版前、拿真 Key，等第四刀的界面）：对一段 720p 的片段做 ByteDance standard 到 1080p：估价 ≈ 0.0072 × 秒数；做完弹对比窗口、
  文件在原片旁边且名字对；替换后片段指向新文件、关键帧 / 标记位置不变；右键换回原片；账单明细几分钟后把实际扣费补上。
