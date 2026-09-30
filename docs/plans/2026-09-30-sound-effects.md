# 音效：合成器（给 AI）+ 录音素材库（给用户）

> 2026-09-30 方案。用户在讨论窗口逐条拍的板见第二节，执行分三个 PR（第五节）。
> **合成器 2026-09-30 三轮试听后定稿**（第六节），第一个 PR（合成器 + 接 MCP，#98）已合并；长期约束在
> [合成音效](../architecture/sound-effect-synth.md)。第二个 PR（素材库清单 + R2）：63 条已在
> `https://downloads.skylu.ai/Audio/SoundEffects/`，管线见 [音频库素材管线](../build/audio-library-pipeline.md) 第八节。
> **当前状态以那些文档和代码为准**。
> 相关：[音频库（音乐 / 音效）](2026-09-22-audio-library.md)、[音频库素材管线](../build/audio-library-pipeline.md)、
> [AI 接口（MCP）](../architecture/ai-control-mcp.md)、[fal.ai 生成](../architecture/fal-generation.md)、
> [声音场景](../architecture/sound-scenes.md)、[阻塞的媒体读取](../architecture/blocking-media-reads.md)、
> [配方卡中文稿](2026-09-28-mcp-recipes.md)、[写代码的规范](../architecture/coding-standards.md)。

## 一、目标

风格卡里的 whoosh / pop / riser / impact 现在只能走 fal 的 `generate_media`（付费、要 Key）：没配 Key 的用户，AI 一个音效都加不了；
用户手动剪也没有音效可拖。分两块：

- **A. 合成器（给 AI，MCP 先做）**：SrtFlow 自己合成剪辑用的动效音（whoosh、riser、impact、pop、叮……），AI 给参数就能生成。
  **真实拟音和环境声不做**（海浪、人群、脚步这类合成不像，交给素材库和 fal）。
- **B. 录音素材库（给用户手动用，AI 也能搜）**：沿用音乐库的路子（清单 + R2 按需下载 + 中英标签），
  **默认不随 App 带、用到才下载**（轻量化）。第一批 = `AI_Video_SouthPole/SoundEffects` 里的 63 个音频。

## 二、拍过的板（2026-09-30）

| 决定 | 口径 | 理由 |
| --- | --- | --- |
| 先试听 | 合成器先在 scratchpad 做原型、渲样音给用户听，用户点头后才写产品代码 | 同当初先听样音再选 Kokoro；合成得不像就别接进产品 |
| AI 调用顺序（用户定） | **先在素材库里找**，没有合适的**用合成器生成**；两边都给不了的真实声音，配了 fal 才走 `generate_media` | fal 那一档是默认口径，用户没反对 |
| MCP 怎么接 | 用户交给我们定（原话「你看怎么方便 AI 调用」），见第四节 | 清单只剩 388 字，不另开工具 |
| 授权 | ElevenLabs 生成的 44 个：付费账号、可用；另 19 个是用户从音乐圈朋友那买的、可以直接用。音频库政策（原来只收 CC0 / CC-BY）**加一条**：作者自己生成或买来、有权分发的音效，默认不要求署名 | 朋友不要求署名；ElevenLabs 付费条款允许商用 |
| 收哪些 | **63 个音频全收**；截图不收；2 个 mp4 是纯音频、转成音频格式；同名变体（`#2 / #3 / #4`、`Inward_Pull` 两个）都收、各自成条 | 没有内容完全相同的文件 |
| 顺序 | 合成器试听 → 合成器接 MCP → 素材库（清单 + 上传 R2 + 面板 + find_audio）。**一个 PR 一件事** | AGENTS.md 合并规则 |
| R2 上传 | **已批准，不用再问**（用户原话「上传批准，不用问」） | — |
| 自写合成器 | AGENTS.md 工程原则 1 说「自写合成器要先征得用户同意」：这次是用户自己提的，**已同意** | — |

## 三、查到的事实（2026-09-30）

### 素材文件夹（69 MB，63 个音频 + 1 张无关截图）

- `转场/` 46 个：44 个 WAV（48 kHz / 16-bit，ElevenLabs 生成，带 C2PA 内容凭证「Eleven Labs Inc.」）：撞击、braam、riser、
  倒吸 suction、shimmer、竖琴刮奏、铺底；2 个 mp4 是 AAC 纯音频（`Cinematic_Suction*`）。
- 根目录 17 个：10 个 mp3（暴风雪 ×3、SnowStorm_A、企鹅、结冰、快速水声、鱼缸气泡、鱼缸水流动、布料撕裂）、
  7 个 WAV（船体吱嘎 ×4、齿轮转动 ×2、科幻机械 ×1）。这 19 个没有内容凭证 = 买来的那批。
- 没有内容完全相同的文件；同名变体是不同的录音。

### 代码现状

- `AudioLibrarySource` 已经有 `.soundEffects`（`https://downloads.skylu.ai/Audio/SoundEffects/manifest.json`，现在 404），
  但只实例化了 `AudioLibraryStore.music`，面板没接音效。方案说「音乐 / 音效不做内层分段，靠筛选区分」（音频库方案第九节）。
- 管线在 `scripts/audio-library/`，文档是 [音频库素材管线](../build/audio-library-pipeline.md)：R2 签名只有 `scripts/r2.py` 一处，
  密钥在 `~/.config/srtflow/r2.env`；音乐规格化是 48 kHz / 192 kbps AAC，原则「宁可响度不统一，也绝不压动态」。
- 风格卡把音效都指向 `generate_media kind=sound_effect`（带货、电影开头、科幻、日常 vlog 四张 + 共用规矩）；改卡先改
  [中文稿](2026-09-28-mcp-recipes.md) 再同步英文，`RecipeChecks` 查卡里的工具名、参数名、选项值都存在。
- `find_audio` 的说明写着「There is no sound-effect library yet; never download music or sound effects from the internet」。
- 清单预算：整份 ≤ 72,000 字，现在 71,612；总说明 ≤ 2,048（现在 1,836，配 fal 1,940）；`checks/MCP/CatalogTextChecks.swift` 钉着。
- 能借的现成东西：`checks/MCP/BeatChecks.swift` 里的合成底鼓；声音场景用系统的 AUReverb2 / NBandEQ / Delay 离线渲染的写法
  （`VideoEditSoundScene`）；配音只经 `AIVoiceLevel` + `AIAudioFileWriter.writeVoiceover` 一处写文件；AI 做出来的文件放
  `AIWorkspace` 的几个文件夹（Exports / Projects / Voiceovers / Generated，名字跟 App 语言）。

## 四、设计（我们定的，动手时可调）

### 合成器

- **预设 16 个**：whoosh、swoosh、suction（倒吸，结尾落点）、riser、downlifter、impact、boom（低音下坠）、hit、pop、click、
  tick、ding、sparkle、beep、glitch、shutter。**默认都短**（用户 2026-09-30：「就像别的，裁剪到就开始那一次声音」）：whoosh 0.9、
  swoosh 0.38、suction 1.2、riser 1.2、downlifter 1.0、impact 1.6、boom 2.0、hit 0.5、pop 0.15、click 0.05、tick 0.08、ding 0.9、
  sparkle 1.2、beep 0.2、glitch 0.4、shutter 0.2 秒；混响尾巴另算、短音效固定只留零点几秒。
- **旋钮**用 AI 好懂的：`duration`、`pitch`（倍数）、`brightness` 0–1、`size` 0–1（干 / 房间 / 大厅）、`variation`（变体种子）。
- **落点 `hit_at`**（给 AI 最有用的一点）：每个预设知道自己「最响那一刻」在第几秒 —— whoosh 在 60% 处、riser / suction 在结尾、
  impact / hit / pop 在开头。工具按 hit_at 反算开头，冲击正好压在切点上。sparkle / glitch 这种一串的，落点是**起点**（第一下），
  之后堆起来更响是设计（`hit_kind: onset`）。
- **确定性**：同预设 + 同参数 + 同种子逐采样一致（SplitMix64，种子 = 预设名 + variation 的 FNV-1a）。可复现、可缓存
  （文件名带参数哈希，同参数复用）。
- **构件**纯 Swift（Accelerate 可选）：正弦 / PolyBLEP 锯齿 / FM；白 / 粉噪声；RBJ 双二阶逐采样扫频；包络、软削波、等功率声像；
  混响用纯 Swift 的 Freeverb（确定、好测；AUReverb2 离线渲染质感好但不确定，留作备选）。
- **电平**：峰值 −1 dBFS 封顶，再把最大瞬时响度（K 加权）压到 −9 LUFS 以下（音调类的声音峰值一样时听着比噪声响得多，见第六节）；
  放进时间线默认比人声低一截；尾巴按 −70 dB 裁掉并淡出。
- **渲出来的文件**放在点名文件夹的 `SrtFlow/音效`（名字跟 App 语言，`AIWorkspace` 加一类）。
- **渲染是几十毫秒的纯计算**（原型：16 预设 × 3 变体 + 9 演示共 0.65 秒），但仍按
  [阻塞的媒体读取](../architecture/blocking-media-reads.md) 的规矩不占 Swift 并发线程池。
- **自检只验结构**：时长、峰值落在 hit_at ± 20 ms、不削波、响度在范围内、同参数逐采样一致、上扬的频谱重心往上走、变体之间不同。
  声音好不好听是人工回归（发版前听一遍）。

### 原型里学到的（写产品代码时照做）

- **Freeverb 的湿声增益随房间大小变得很厉害**（大房间对持续输入的稳态增益近 9 倍）：按固定系数混，impact / ding 的峰值被混响
  堆起来推后 100–400 ms、suction 的峰值跑到结尾前 200 ms。改成**湿声按干声峰值的比例混**（`mixReverb`：湿声峰值 = 干声峰值 × 比例 × size），
  落点才可预期。
- **落点要能验**：riser 的颤音相位要算到「最响的一拍停在结尾前 10 ms」（总周期数 = ∫(3+13u)du · dur = 9.5 · dur），
  不然差一拍就早 55 ms；boom 软削波把波形压平后「峰值时刻」没意义，包络要分快慢两段让开头明显最响；
  downlifter 倒过来之后还要再叠一层衰减。
- 变体之间只换随机种子和 ±5–10% 的抖动，听起来是「同一种声音的不同一次」。

### MCP 接法（按 [AI 接口](../architecture/ai-control-mcp.md) 第一节第 5 条，先看加参数行不行）

- **录音素材**：
  - `find_audio` 加 `kind: music | sound_effect | any`，两个来源同一个搜索函数（`AudioLibraryManifest.filter`）。
  - 结果带时长、标签和 `hit_at`（入库时量好：短时 RMS 最大的那一刻）。
  - `add_clips {library_id, hit_at}` 照旧走 `AITimelineEdits.place`。
- **合成音**：
  - `add_clips` 的条目加第三种来源 `sound_effect: {preset, duration, pitch, brightness, size, variation}`，和 `file` / `library_id`
    并列，带 `hit_at`。一批一次调用、一步撤销，默认放进新开的音效轨。
- **说明里写清顺序**：先用 `find_audio` 找录音，没有合适的用 `sound_effect` 生成，真实声音都没有才用 `generate_media`。
- **总说明目录**里 Sound 那一行改成类似「find_audio (music and sound effects), add_clips sound_effect (made on this Mac: whoosh, riser,
  impact…), add_voiceover, set_track」。总说明仍要 ≤ 2,048。
- **清单要腾出约 1K 字**（现在只剩 388）：先把长说明写短。
- ai-control-mcp.md 第四节加一条；风格卡从 `generate_media` 改成本地音效（先改中文稿）。

### 素材库

- 走 `scripts/audio-library/` 管线，加音效一路：
  - 转成 48 kHz / 192 kbps AAC；2 个 mp4 抽出音轨。
  - **音效的规格化口径**：峰值归一到 −1 dBFS、**不做响度归一**（音效的动态就是它的全部），写进管线文档。
  - 中英标题和标签，按文件名 + 量出来的特征起草（时长、频谱重心、有无冲击）；量 `hit_at`。
  - `license` 用新的「自有 / 已授权」类别（`owned`），署名句为空、署名页不列。
- 上传到 R2 的 `Audio/SoundEffects/`（`AudioLibrarySource.soundEffects` 已经指着它），已批准。
- 面板接上音效来源：第二个 store、按 tag 筛选，试听和拖进时间线跟音乐一样。
  - 新视图要接性能计数（`checks/preview-perf-wiring.sh --fix`）。
  - 新文案两张表都要有；sheet / popover 套 `.appLanguage()`。
- 授权政策写进 [音频库方案](2026-09-22-audio-library.md) 第十节和 [管线文档](../build/audio-library-pipeline.md) 第二节。

## 五、分刀（三个 PR，各从最新 main 开分支）

1. **合成器 + 接 MCP**：`Sources/SrtFlow/SoundEffects/`（DSP 地基、预设分文件，每个 ≤ 400 行）、`add_clips` 的 `sound_effect` 条目、
   `AIWorkspace` 加音效文件夹、总说明 Sound 那一行、ai-control-mcp.md 第四节加一条、风格卡改指向本地音效（先改中文稿）、
   `scripts/check-mcp.sh` 里的结构自检。本方案文档跟这个 PR 一起提。
2. **素材库清单 + 上传 R2**（2026-09-30 做完）：`sfx-catalog.tsv` + `sfx_normalize.py` + `sfx_build_manifest.py`、63 条转好上传、
   `checks/sfx-catalog.sh`；授权政策进两份文档。清单里多了 `hit`、`title_zh`、`provenance`、`owned`，App 还没接。
3. **面板 + find_audio**（2026-09-30 做完）：`AudioLibraryStore.soundEffects` + 面板顶上「音乐 / 音效」分段（同一套搜索、筛选、试听、
   拖入；音效的 tag 多一组「种类」排最前；一行拆成 `AudioLibraryRow`）；`AudioLibraryLookup` 两个库一起找（重链接、library_id、署名）；
   `find_audio kind`、结果带 `hit` / `title_zh`；`add_clips {library_id, hit_at}`；音效段默认 −8 dB（`SoundEffectClipGain`，面板和 AI 同一个数）；
   App 解析 `hit` / `title_zh`、`owned` 不署名（`AudioLibraryLicense.needsCredit` 一处，署名页、music_credits 都问它）；
   风格卡共用规矩第 12 条改成「先搜库、再合成、再 fal」。

## 六、试听原型（2026-09-30 渲出，等拍板）

原型在会话的 scratchpad（`sfx-proto/`：`DSP.swift` / `Presets.swift` / `Hits.swift` / `Tones.swift` / `main.swift`，
`xcrun swiftc -O -target arm64-apple-macosx15.0` 编成小程序），产物 `out/`：16 个预设各 3 个变体连放（间隔 0.7 秒）、
三个旋钮演示（whoosh 三种长度、riser 三种长度、impact 三种空间）、`参照-素材库/` 里 9 个 ElevenLabs 文件对着听、
`README-先读这个.md`、`stats.txt`。**第一个 PR 会把源码搬进仓库**，scratchpad 那份是临时的。

结构检查（自动量的）：全部文件峰值 −1 dBFS；实测峰值离声明落点大多 ≤ 20 ms（whoosh、downlifter 噪声主导 ±60 ms；sparkle / glitch 落点是起点）；
whoosh 的频率重心先升后降、riser 一路升、suction 升到结尾、downlifter 一路降；同参数渲两次逐采样一致。

**决策门（等用户听完）**：

- 逐个预设：留 / 改 / 不要。
- whoosh、suction、riser、impact 和 ElevenLabs 那批比：**明显不如** → AI 那边以素材库为主，合成器只留 pop / click / tick / ding / beep
  这类简单音效；**够用** → 合成器接 MCP，风格卡里的 whoosh / riser / impact 改指向它。
- 变体之间的差别够不够。

决定写在这一节下面，第一个 PR 按决定做。

### 第一轮（2026-09-30）用户听完的结论

- **除 riser、downlifter、ding 之外全部通过**（原话「别的没有问题」）→ 合成器接 MCP，风格卡里的 whoosh / riser / impact 改指向它。
- **riser（含三种长度的演示）「听着不太舒服、不自然」，downlifter 同样，重做**；**ding 音量太大，降**。
- 「变体之间差别够不够」这个问题用户没看懂，不追问：变体只换随机种子和 ±5–10% 的抖动，就这么定。

### 第二轮的做法（重做前先量参照文件，不再凭空猜）

用 Accelerate 写的小分析器量 ElevenLabs 那批（每 100 ms 的 RMS、频谱重心、频谱平坦度、左右相关、结尾形状）：

| 文件 | 形状 |
| --- | --- |
| `Kinetic_Lift`（4 s，最像我们要的 riser） | 音量按 **dB 线性**上升（−57 → −16 dB）；频谱重心 1 kHz → 5.4 kHz、平坦度 0.05 → 0.5（从偏音调、暗，到宽噪声、亮）；左右相关 ≈ −0.1（很宽）；结尾 400 ms 平着到顶、文件到头就切，没有尾巴 |
| `Sustained_Ascent`（20 s）、`Apex_Ascent`（30 s） | 低音**音调**的长铺垫（重心 80–400 Hz、平坦度 0）、最响在 40–60%、结尾淡出。不是转场 riser，是 drone |
| `The_Descent`（4 s）、`Ominous_Descent`（10 s） | 都是**低音音调**「涌起到 21% 处最响，再一路掉到无声」，重心 80–400 Hz、平坦度 0，**不是噪声** |

第一版 riser（3 个锯齿 110→880 Hz + 3→16 Hz 越来越快的 70% 颤音 + 8 ms 硬切）和这个形状差很远：锯齿像警笛、颤音像直升机。
第二版按量出来的做：

- **riser**：两路独立的粉噪声（左右不相关）过一对打开的低通（800 Hz → 14 kHz）+ 抬高的高通（100 → 800 Hz）；一条 Q = 3 的带通噪声
  （500 Hz → 5 kHz）给开头的口哨感；一层很软的音调（正弦 + 弱 2、3 次泛音，165 → 330 Hz，比重从 0.35 降到 0.2）垫底；
  没有颤音；音量从 −36 dB 按 dB 线性升到 0，结尾 15 ms 收掉；混响 size 0.3。落点 = 结尾。
- **downlifter**：低音音调（同一种软音色）在前 40% 从 110 Hz 掉一个八度，音量前 12% 平滑涌起、之后按 τ = 0.3·dur 指数衰减；
  一层暗下去的气声（低通 3 kHz → 300 Hz）；中等混响。**落点 = 涌起到顶的那一刻**（0.12·dur），不再是开头。
- **响度**：原来全按峰值 −1 dBFS 归一，纯音调的 ding 峰值一样时 K 加权响度 −2.5 LUFS、比 whoosh（−9.4）响 7 dB。
  改成 **峰值 −1 dBFS 封顶 + 最大瞬时响度（BS.1770 K 加权、400 ms 窗）≤ −9 LUFS**，−9 定在用户已点头的 whoosh / impact 上，
  它们不变；ding 降 6.5 dB、beep 5、glitch 5、sparkle 3.5、boom 3（boom 是唯一动了的已点头的，等用户说）。这条进产品。

### 第二轮用户听完（2026-09-30）：「这三个可以，不过不用时间这么长，就像别的，裁剪到就开始那一次声音就可以了」

- riser、downlifter、ding 的声音定了，**只是太长**。默认时长改短：riser 2 → **1.2 秒**（上扬）、downlifter 2 → **1 秒**、
  ding 1.5 → **0.9 秒**（余音 τ 0.7 → 0.35）；这三个的混响尾巴不靠 −60 dB 裁（还是太长），**文件固定只留 dur + 0.35–0.4 秒、末尾淡出**
  （`limitTail`）。尾巴的裁切门限全体从 −70 改 −60 dB（听不出差别，文件短一截）。
- 试听文件里这三个只放一次（用户听的是「一次声音」；产品里本来就是一次调用一个声音）。

### 第三轮用户听完（2026-09-30）：「可以，没有问题」→ 合成器定稿

原型源码搬进 `Sources/SrtFlow/SoundEffects/`（第一个 PR），长期约束写进 [合成音效](../architecture/sound-effect-synth.md)。

### 第一个 PR 的端到端冒烟（2026-09-30，测试版 0.18.3，`scripts/gui-smoke/mcp-client/client.py`）

调用表：open_folder（scratchpad 里 ffmpeg 现做的 20 秒 test.mp4）→ new_project → add_clips 放视频 → add_clips 一批五个音效
（whoosh / impact / riser 都 `hit_at` 12.0，pop 0.3，suction 0.5）→ get_timeline → listen → 同参数再放一个 whoosh（`hit_at` 15）→
错的预设名 → undo round=true → get_timeline。结果：

- 开头 = hit_at − 声音里的落点：whoosh 11.446（落点 0.554）、impact 11.995、riser（1.5 秒）10.481、pop 0.298；suction 的落点在结尾、
  1.2 秒放不进 0.5 秒 → 开头 0、`source_in` 0.714，落点照样在 0.5。段的 `volume_db` −8。
- 写出来的 .m4a 用 ffmpeg 解回来量峰值：impact 0.014 s、pop 0.002 s、riser 1.505 s（结尾）、suction 1.195 s（结尾）、whoosh 0.532 s ——
  和渲染时一致，**AAC 的编码延迟被容器补偿了**，落点不用另外扣。
- `listen` 的 `loudest_at` 是 0.5 秒粒度，验不了 ±20 ms 的落点；验落点看解码后的峰值。
- 同参数的 whoosh 第二次没再写文件（文件夹里 5 个 .m4a，`whoosh-314d87b8.m4a` 复用）；错的预设名回「preset must be one of: …」；
  撤销整轮后时间线空。
- 文件夹名跟 App 语言：测试版是英文，就是 `SrtFlow/Sound Effects/`。

### 第三个 PR 的端到端冒烟（2026-09-30，测试版 0.18.4，`calls-library.json`）

- `find_audio {query: impact, kind: sound_effect}`：10 条命中，每条带 `kind: sound_effect`、`hit`、`title_zh`、`license: owned`、没有署名句；
  `{query: "撞击 黑暗"}`（不给 kind）按中文 tag 命中 8 条；`{query: piano, kind: music}` 只回音乐、带署名句。
- `add_clips [{library_id: sfx_0009, hit_at: 12}, {library_id: sfx_0027, hit_at: 12, track: new_audio}, {library_id: sfx_0051, start: 2}]`：
  Cinematic Slam（落点 0.045）开头 11.955、Kinetic Lift（落点 3.955）开头 8.045（从 R2 现下，一批 4.3 秒）、企鹅按 start 放且结果报 `hit_at` 9.565；
  三段 `volume_db` −8；`get_timeline` 里写 `library_id`。
- 给普通文件带 `hit_at` → 「hit_at works with sound_effect and library sound effects; place a file with start.」
- `undo round=true` 一步清空。
- 面板那一半（分段切换、音效列表、tag 排序）自动化够不着，看真窗口（进程内驱动点不了分段控件，第 12 条）。

## 七、检查与回归（AGENTS.md 要求）

- 合成器：`scripts/check-mcp.sh` 加一块（结构自检，见第四节）；接线守卫：写文件只经一处（同配音）、渲染不在并发线程池里阻塞。
- 素材库清单：`scripts/check-audio-library.sh` 加 `owned` 这一类授权（解析、署名页不列）。
- MCP 文字：`CatalogTextChecks` 照旧（总说明 ≤ 2,048、目录里有每个工具名、清单 ≤ 72,000）。
- 人工回归（发版前）：听一遍 16 个预设；在真工程里让 AI 「在切点上放个 whoosh」，看冲击是不是压在切点上；面板试听、拖入、断网用旧清单。
