# fal.ai 生成：Key、每日上限、模型表、generate_media、配旁白的 fal 那一档

> 2026-09-29 引入（MCP 方案第 6 块，[第 14–19、36、42、52、57、58 条](../plans/2026-09-27-mcp.md)）。改 `Sources/SrtFlow/Fal/`、
> `AIFalVoice` / `AIFalVoices`、`generate_media` 的说明和参数、设置里的 fal 一节、`MCPProviders`（清单按 Key 列不列）、
> `add_voiceover` 的 fal 档之前必读。相关：[AI 接口（MCP）](ai-control-mcp.md)（第四节第 39、40 条）、[阻塞的媒体读取](blocking-media-reads.md)、
> [本地化](localization.md)。

## 一、落点

| 决定 | 口径 |
| --- | --- |
| 谁能用 | 用户在设置 → AI 里填**自己的** fal.ai Key（第 14 条）；不填就没有这一块：`generate_media` 不出现在清单里（第 36 条），配旁白照旧走本机 / macOS |
| 调用方式 | `URLSession` 直接调 fal 的队列 HTTP 接口，不引 SDK（第 14 条）。`FalClient` 是**唯一**碰 fal 地址的地方 |
| Key | 能添加、能删除，存系统钥匙串，先只管一把（第 17 条）。见第六节 |
| 花钱 | **只设每天的上限，默认 10 美元，用户能改；不设单次上限；额度内不问，超了先问；没登记单价的模型每次都先问**（第 18 条）。按登记的单价估，不是 fal 的账单。见第五节 |
| 模型 | 每种事一个预设，用户能改成自己的端点号和单价（第 19 条）；对话里点名别的端点也能用（价格不明，每次问）。**2026-09-29 用户定：视频只用 `minimax/h3-max/` 这个系列；音乐、音效也加上；预设只用当前最新的模型，太老的不要**（第 57 条）。见第二节 |
| 生成是任务 | 回任务号，AI 用 `get_job` 等，停止 / `cancel_job` 能取消（第 5 条）；成品放用户的 `SrtFlow/生成`（点名的文件夹 → 工程的家 → 下载；撞名加编号）。**不改工程**：放上时间线是 `add_clips` 的事 |
| 配旁白 | 三档谁可用就用谁：**fal > 本机 Kokoro > macOS**（第 42 条）。配旁白是同步工具，**不许停下来问用户**：额度不够就退到下一档并在结果里说为什么（第 58 条）。克隆（第 52 条）只有 fal 能做，用不了就报错、不退档 |

## 二、预设怎么选、怎么更新

**选法**：fal 有公开的目录接口（`https://api.fal.ai/v1/models`，不用 Key），带每个模型的类别和上架日期。2026-09-29 那天按日期排、每类取
最新的、单价固定或能估、接口能拿到我们要的东西的那一个；用户点名的例外（视频）单列。列表和挑的理由：

| 种类 | 端点 | 上架 | 单价（页面上「Your request will cost …」） | 为什么是它 |
| --- | --- | --- | --- | --- |
| 图片 | `bytedance/seedream/v5/flash/text-to-image` | 2026-09-23 | $0.027 / 张 | 图片类里最新；单价固定。GPT Image 2.5（09-08）按 token 计价、随质量差二三十倍，估不准；Nano Banana 2 是 02-26 的，太老 |
| 文生视频 | `minimax/h3-max/text-to-video` | 2026-08-23 | 按分辨率每秒：480p $0.05、768p $0.08、1080p $0.16 | **用户点名**：`minimax/h3-max/` 系列。带同步的声音（环境声、拟音、配乐）；5–15 秒 |
| 图生视频 | `minimax/h3-max/image-to-video` | 2026-08-23 | 同上 | 同上；画幅跟着那张首帧图 |
| 旁白 | `elevenlabs/tts/eleven-v4` | 2026-09-28 | $0.08 / 千字符 | 旁白类里最新（Gemini 3.8 Flash TTS 09-25 不报词时间）；能报每个词的时间（配字幕要）；音色名 fal 在字段例子里列全了 |
| 克隆 | `fal-ai/zonos2` | 2026-06-16 | $0.01 / 成品分钟 | 一步就能按参考音频克隆的里最新的（MiniMax 的克隆是 2025-05 的、两步、一次 $1.5，太老） |
| 音乐 | `elevenlabs/music/v2.5` | 2026-09-14 | $0.6 / 成品分钟，不满一分钟按一分钟 | 有 `force_instrumental`（视频配乐几乎都要纯音乐）和 `music_length_ms`（时长可控）。Lyria 3.5（09-19）没有这两个开关；MiniMax Music 3（08-13）歌词必填、没有纯音乐开关 |
| 音效 | `sonilo/v1.1/text-to-sound-effects` | 2026-07-20 | $0.0018 / 成品秒 | 专做音效的里最新，时长可控（0.5–180 秒） |

**H3 Max 的价格**：页面上现在写的是上线促销价（一半，2026-09-30 结束）；登记的是**正式价**（`FalModels.h3MaxTierPrices`），估价宁多勿少。

**更新的做法**（别靠记忆，fal 的目录天天在变）：`scripts/fal-models/refresh.sh`（要联网，不在 `check-all` 里）——
无参数：重下每个登记端点的接口定义快照（`checks/Fal/schemas/`），说哪些变了；`--newest [N]`：按上架日期列各类最新的；`--prices`：抄每个登记端点页面上的
价格那一句，和 `FalModels.swift` 里登记的对一遍。换预设 = 改 `FalModels.known` + `FalDialect.byEndpoint`（请求怎么写）+ 重下快照 + 改上面这张表的日期和单价；
`scripts/check-fal.sh` 会把「登记表、写法表、快照三样对不上」逮住。

## 三、请求怎么写（`FalInputs`）

- 每个登记端点各有一种写法（`FalDialect`）。字段名、取值范围、必填项**是从 fal 公开的接口定义读的**
  （`https://fal.ai/api/openapi/queue/openapi.json?endpoint_id=…`），定义的快照放在 `checks/Fal/schemas/`，
  自检把造出来的请求体逐条**对着快照验**（必填、取值、范围、多余字段）—— 请求体写错是第一次拿真 Key 才会露馅的那类错，这里没有 Key 就能红。
- 踩到的两处：`prompt_expansion_mode` 在 H3 Max 的定义里是**必填**（虽然有默认值）；文生视频有 `aspect_ratio`、图生视频**没有**（画幅跟着首帧图，多发会被拒）。
- 时长按模型认的范围夹（H3 Max 5–15 秒、音乐 3–600 秒、音效 0.5–180 秒），估价用夹过的数；分辨率认 `480p` / `768p` / `1080p`（默认 768p，AI 做草稿用 480p）。
- 画幅：图和文生视频默认跟画布（`FalInputs.nearestAspect`）；Seedream 的常见画幅有现成的名字（`landscape_16_9` …），别的按宽高写（约 250 万像素、16 的倍数）。
- 本地图片（图生视频的首帧）编成 **base64 data URI** 直接放进请求（fal 各个模型页都写「文件字段收网址或 data URI」）；太大（>6 MB）或 fal 不认的格式先用 ImageIO
  缩到长边 2048、存 JPEG（`FalPayloads`）。克隆的参考音频同理（16 kHz 单声道 WAV）。
- `options`：AI 直接传给模型的其余字段，盖在 SrtFlow 填的上面。**没登记的端点只写最基本的字段**（`prompt` / `text`、`image_url`），其余全靠 `options` ——
  它点名了这个模型，就该知道它的参数。

## 四、队列接口（`FalClient`）

- `POST https://queue.fal.run/<端点号>` 提交 → 回 `request_id` 和 `status_url` / `response_url` / `cancel_url`，**照它给的地址用，不自己拼**
  （没给才按端点号推）→ 轮询状态（`IN_QUEUE` / `IN_PROGRESS` / `COMPLETED`；完成了却带 `error` 就是做失败了）→ 取结果；取消 = 对 `cancel_url` 发 `PUT`。
  认证头 `Authorization: Key <密钥>`。前几次问得勤（1 秒），之后每 2–4 秒。
- **取消必须在不继承取消的 Task 里发**（`cancelDetached`）：调用者的 Task 已经被取消时，URLSession 的 async 接口一看见取消就不发请求，直接 `await cancel` 的话 fal
  那边其实没被取消。这是写自检时用假协议逮到的（撤掉那一行，「fal 被要求取消了」一条得 0 不是 1）。
- 每种失败换成一句给 AI 看的话（`FalError.message`）：401 = Key 不对、403/402 = 余额用完或账号被锁（指去 fal 的账单页）、422 = 请求不合格（带上是哪个字段）、
  429、5xx、完成了但做失败、超时（替 fal 也取消）、网络。Key 相关的话都写「去设置 → AI」。
- 一次生成最多等多久：图 / 音效 / 旁白 5 分钟、音乐 15 分钟、视频 25 分钟（`FalModel.Kind.maxSeconds`），超了替 fal 取消。
- 下载：先下到临时文件再挪过去，下到一半断了不留半个文件；空文件、HTTP 错误都报错；**不把 Key 发给文件那台主机**。
- 自检 / 冒烟用 `SRTFLOW_FAL_QUEUE_BASE` 把队列地址指到本机的假 fal，**只认回环地址**（Key 不会因此发到别处）。

## 五、花钱（`FalSpendPolicy` / `FalSpendLedger` / `FalGenerationRun`）

1. **估算** = 登记的单价 × 用量（`FalModel.estimate`：图按张、视频按秒（分辨率分档）、旁白按千字符、音乐按成品分钟向上取整、音效按秒）。
   没登记单价（用户填了自己的端点又没填价、或 AI 点名的端点）估不出来 = nil。
2. **判断**：`今天已花 + 这次估算 ≤ 上限` 就直接做；超了、或估不出来，先问。上限 0 = 什么要钱的都问。差不到一美元的千分之一不算超。
3. **问 = 提示条上两个按钮**（`AISession.ask`：允许 / 先不要，还有停止），**不弹模态框**（方案第 9、10 条）。任务是 running、带 `waiting_for_user`
   （AI 转述给用户、继续 `get_job`）；同时有几个问题一个个问。问的时候把 SrtFlow 摆到前面，**并先把剪辑页摆出来**（`AIEditorPresenter.prepareEditor`）：
   提示条只挂在剪辑页里（`VideoEditView`），用户此刻在压缩 / 烧录这些栏目时问题看不见、任务会一直等（2026-09-29 拍窗口截图才发现；`checks/fal-wiring.sh` 钉着先后）。
   后台模式也照摆：要用户点头的事不能悄悄等。
   **提示条不管这一轮是什么状态都把问题摆出来**：AI 在等结果时这一轮早就「结束」了，条不能因此收起来（`checks/fal-wiring.sh` 钉着顺序）；
   按停止 / `cancel_job` 把问题收回，算「不要」。
4. **决定和记账在同一步里做完**（中间没有 await）：同时起的几个任务不会各自以为还在额度内。记的是估算，按**本地自然日**、存 UserDefaults（`FalSpendLedger`，只留 40 天）。
5. **没做出来的退回，做出来了的不退**：失败 / 取消 / 超时退回估算；已经拿到结果、后面下载出了问题不退（fal 已经收了钱）。
6. **配旁白不问**：同步工具，客户端一分钟左右就超时。`FalSpendPolicy.allowsWithoutAsking`：额度不够 / 价格不明 / Key 读不出来 → 退到下一档声音，
   结果里 `voice.note` 写「fal.ai 的声音没用：会让今天超过 $X 的上限」并说去设置里改。
7. 每日上限、今天花了多少、每种事的模型都在设置 → AI 的 fal 一节（`FalSettingsRow`），`get_status` 的 `generation` 也报给 AI。

## 六、Key 与钥匙串（`FalKeyStore` / `FalKeyCache`）

- 一条通用密码项：服务名 = bundle id + `.fal`（测试版是另一个 bundle id，另一条），账号 `api-key`。粘进来的先整理：去掉 `Key ` 前缀、引号、首尾空白 / 换行；
  中间有空白或太短就不收。
- **2026-09-29 本机探针量出来的行为**：只查属性（有没有存过）不弹授权框；读密钥本身时，只有创建这一项的那个签名能免弹窗读。App 是 ad-hoc 签名，
  **每出一个新版本签名就变了，第一次读会弹 macOS 的「要使用钥匙串里的机密信息」框**，点「始终允许」之后这一版不再弹。
- 所以读分两档：`.silent`（`kSecUseAuthenticationUIFail`：要弹框就直接回「需要授权」）和 `.interactive`（弹框、等用户点）。**别改成 `LAContext.interactionNotAllowed`**：
  探针里它拦不住老式（文件）钥匙串的授权框，进程卡在框上等人点。任务里先试 `.silent`，需要授权时先在提示条上说一句「macOS 马上会问，请点始终允许」，
  再在后台线程上弹（不占主线程）；读到之后记在内存里（`FalKeyCache`），**一次运行最多弹一次**。
- 不用 data-protection 钥匙串：它要 entitlement，ad-hoc 签名的 App 用不了。
- 用户在设置里存 / 删 Key 时不读回来（读就可能弹框）：直接把刚存的记进 `FalKeyCache`。
- **取舍待用户拍板**：发布给别人的 Developer ID 签名版本签名稳定，只弹一次；ad-hoc 的测试版每个新版本弹一次。要免弹只能把项的访问控制放宽成「任何应用」（等于普通文件的安全性）
  或干脆存文件。现在按第 17 条存钥匙串、默认访问控制。

## 七、清单跟着 Key 走（`MCPProviders`）

- 工具清单由小程序（`srtflow-mcp`）当场回（Claude 一启动就要，不能为此拉起 App），而 Key 在 App 的钥匙串里，所以 App 在 Key 添加 / 删除时、以及每次启动时，
  写一个**只有提供方名字**的小文件 `mcp-providers.json`（`{"providers":["fal"]}`，和 socket 同目录、按 bundle id 分开），小程序每回一次清单 / 握手都重读它。
  文件里没有 Key、没有别的机密；读得宽（不在 / 坏了 / 有不认识的名字都当没有）。
- 没配：`generate_media` 不列出来、总说明里也不提它（`MCPInstructions.text(providers:)`）。配了：列出来、总说明的目录末尾多一行（只指路：
  生成什么、要花钱）；花钱怎么问、每日上限、先告诉用户估价写在 `generate_media` 自己的说明里 —— AI 调它之前一定读得到，而总说明在
  Claude Code 里只读前 2,048 字（[AI 接口（MCP）](ai-control-mcp.md) 第一节第 6 条）。
- 清单会变，所以：握手声明 `tools.listChanged = true`，小程序每 2 秒看一眼那个文件，变了就给**握过手的老一代客户端**发 `notifications/tools/list_changed`；
  新一代（2026-07-28）没有会话，靠清单的缓存时间 —— `tools/list` 的 `ttlMs` 从一小时降到一分钟（`MCPServerCore.toolListTTLms`）。
- 说明总长度的上限（72,000 字符）量的是**每个提供方都配好**时的全清单：2026-09-29 配齐时 70,377（没配 fal 时 67,208；`generate_media` 整条 3,169、说明 1,685）。
  余量只剩不到 2 千，以后再加工具要先把别处写短。

## 八、generate_media（`FalGenerateTool` / `FalGenerationRun`）

- 参数：`kind`（image / image_to_video / text_to_video / music / sound_effect）、`prompt`，其余按种类：`image`（图生视频的首帧文件，点名文件夹以外的先问一次用户，
  同读别处的文件：图会发给 fal）、`duration`、`resolution`、`aspect_ratio`、`instrumental`、`name`、`model`、`options`。旁白不走它（`add_voiceover`）。
- 立刻回任务号，带 `estimated_cost_usd`、今天已花、每日上限、`next_step`（告诉用户估价、用 `get_job` 等、做完用 `add_clips` 放上去；音乐音效放 `new_audio`）；
  跑着的 `get_job` 带阶段（`phase` / `queue_position` / `transfer_percent` / `phase_seconds` / `typical_seconds`，第十三节）；
  完成的 `get_job` 带 `file`、`cost_usd`、宽高 / 时长（fal 报了的话）。H3 Max 的视频自带声音（环境声、拟音、配乐），**随片段一起播、不另开音频轨**（冒烟实测：放上时间线只有 V1 一个片段）——再配音乐 / 旁白时要压低或静音这个片段的音量（结果的 `note` 告诉 AI）。
- 成品文件是 SrtFlow 自己做的：登记进「AI 可以读」的地方（`AIReadGrants`，不在点名文件夹 / 工程的家里时），AI 接着 `add_clips` 不会再被问。
- 不改工程、不进撤销分组、不算这一轮的改动（`checks/fal-wiring.sh` 钉着路由）。

## 九、配旁白的 fal 档（`AIFalVoice` / `AIFalVoices` / `AIVoiceChoice`）

- 能用 fal 的条件（`AIFalVoice.offer`）：有 Key、这一批字不会让今天超过上限、Key 读得出来。三样有一样不行就退档（并说为什么，没接 fal 时什么都不说）。
- 挑音色：没点名按文字的语言取温和的角色的音色；点名角色换成对应的 ElevenLabs 预制音色（`AIFalVoices.byRole`，和 `AIVoiceRole.all` 一一对上，自检对账）；
  点名 ElevenLabs 的音色（`Rachel`、`Brian`…，大小写不敏感）照用；点名 Kokoro 的音色或这台 Mac 的声音仍照点名。名字撞了（Daniel 两边都有）fal 可用时按 fal。
- Eleven v4 没有语速参数：`speed` 被忽略，结果里说一句。
- 读一句：提交 → 下载到临时文件 → 解码成单声道 → **经 `AIAudioFileWriter.writeVoiceover` 落盘**（音量和文件格式只有一处说了算，和另外两种声音同一份，
  `scripts/check-mcp.sh` 那条扫描钉着）→ 记账。
- **词时间**：要字幕时请求 `timestamps`；fal 没写元素的形状，认三种常见写法（`{word|text, start, end}` 的对象、`[text, start, end]`、ElevenLabs 的按字符对齐）；
  换成字幕认的词（`AIFalVoices.timedWords`：英文词带前导空格、中日韩不加空格、时间夹进音频长度）；**词的字数和原文对不上（差三成以上）就不要** ——
  没有词时间字幕只是没有，不会错位；结果里 `subtitles.note` 告诉 AI 改用 `generate_subtitles`。
- 克隆（`clone_from`）：一段素材里有人声的地方（`clone_start` / `clone_seconds`，5–30 秒）→ 16 kHz 单声道 WAV → data URI → Zonos2。整段几乎没声音就说清楚。
  素材在点名文件夹以外要先问用户（声音会发给 fal）。用不了 fal 就报错，不退档（别的声音克隆不了）。

## 十、已知不足（真 Key 第一次要对的）

自动检查没有 Key、也不该花用户的钱，下面这些**没有对真的 fal 验过**，第一次用真 Key 时逐条看：

1. Eleven v4 的 `timestamps` 元素长什么样（接口定义里元素是空的）：读不出来就没有词时间，字幕退回没有；
2. 每个登记端点的实际产出（我们只对着接口定义验了请求体和样例输出的形状）；
3. 中文旁白用哪个音色好听：角色表是按 ElevenLabs 的音色描述配的，没有听过；
4. Zonos2 读中文的效果、参考音频 16 kHz 够不够；
5. H3 Max 促销价 2026-09-30 结束后的正式价（登记的是正式价，估价偏高不偏低）；
6. 估算不是账单：估价用登记的单价，fal 改价或换计费方式（比如 GPT Image 2.5 按 token）会偏。

## 十一、回归与人工清单

- `scripts/check-fal.sh`（`check-all` 第 2 组，不碰网络、不碰钥匙串）：模型表与估价、花钱把关、按天记账、**每个端点的请求体对着接口定义快照验**、样例输出与词时间、
  `FalClient` 走全流程（假 URLSession：提交 / 三次轮询 / 取结果、照 fal 给的地址、每种失败换的话、Task 取消和超时都替 fal 取消、下载收尾、没 Key 时一个请求也不发）、Key 的整理；
  **视频 upscale**（第十二节）：六个档位的端点都有快照、每个档位 × 每档目标 × 几种源的请求体对着快照验、倍数按模型夹、估价钉在 2026-10-02 的账单上（只高不低）、
  上传（initiate 带 Key、PUT 不带、体是文件字节、`gcs` 被拒的那种错怎么报）、账单明细的查询和解析。
  **反向验证**做过：漏发必填的 `prompt_expansion_mode`、时长不夹、分辨率不规整、多发字段、上限刚好算超、取消不走 detached、Bearer 头、不用 fal 给的地址、
  音乐不满一分钟不向上取整、登记表对不上写法表、视频换成别的系列，各红。
- `scripts/check-mcp.sh` 的 `ProviderChecks`（清单按 Key 列不列：真起小程序，老一代收 `list_changed`、新一代不收；小文件的读写）和 `FalVoiceChecks`（挑音色、词时间、WAV）。
  反向验证：目录不按提供方过滤、握手不认会话、缓存时间不降、不发通知、总说明不分、小文件每次都写，各红。
- `checks/fal-wiring.sh`（扫描守卫，`check-all` 第 1 组）：fal 的文件里没有模态框、HTTP 只经 `FalClient`、Key 只经 `FalKeyCache`、先 `decide` 后 `run`、`reserve` 恰好两处、
  没拿到结果才退账、提示条上的问题先于 `switch phase`、停止 / 取消收回问题、配旁白里没有 `.ask(`、清单跟着 Key 走、路由不进撤销分组。每条都反向验证过。
- `scripts/check-fal-keychain.sh`（**本机手动**，不在 `check-all` 里：要一个能用的用户钥匙串）：存 → 有 → 读到 → 换 → 删；改 `FalKeyStore` 之后跑。
- `scripts/fal-models/refresh.sh`（要联网，手动）：见第二节。
- **人工回归**（发版前、拿真 Key）：
  1. 设置 → AI 里填 Key、保存：出现「密钥已存入钥匙串」，AI 客户端的工具清单里多了 `generate_media`（老一代客户端马上多、新一代一分钟内）；删除后没了；
  2. 让 AI 生成一张图、一段 5 秒 480p 的视频、一段音乐、一个音效：任务号 → `get_job` 出 `file`；放上时间线能播；视频带着声音；今天已花的数变了；
  3. 把每日上限改成 0.01 再让 AI 生成：提示条上出现问题（不是弹框），SrtFlow 在最前面；点「先不要」任务结束、没花钱；再来一次点「允许」才做；
  4. AI 在等结果的时候（超过 30 秒）问题还挂在条上；按停止后问题收掉；
  5. 让 AI 配旁白：用 fal 的声音（结果里 `voice.name` 是音色名）；要字幕的话有字幕（或结果里有说明）；上限改成 0.01 后自动退到下一档、结果里说为什么；
  6. 用 `clone_from` 指一段自己的录音：出来的旁白像那个人；
  7. 装新版本后第一次生成：提示条先说「macOS 马上会问」，点「始终允许」后继续，之后不再弹；
  8. 点名一个没登记的端点（`model`）：先问（价格不明）。

## 十二、视频 upscale 的地基（2026-10-02 起）

> 来龙去脉和用户拍的板在 [视频 upscale 方案](../plans/2026-10-02-video-upscale.md)，实测数字在 [smoke test 实测](../reports/2026-10-02-upscale-smoke-test.md)。
> 这一节只记长期约束。改 `FalUpscaleModels.swift`、`FalBilling.swift`、`FalClient.upload` / `billingEvents` 之前必读。

| 决定 | 口径 |
| --- | --- |
| 档位 | **六个、四个端点**（`FalUpscaleTiers.all`，顺序就是界面的顺序）：Topaz precision（`Proteus`，真人脸）、Topaz generative（`Starlight Precise 2.6`，重绘细节）、FLUX precise / creative（`creativity` 0 / 1，**0 要显式传**，fal 默认是 1）、字节 standard / pro（`aigc` 预设、`fidelity high`、`scale_ratio`、**`target_fps` 传源帧率**，不传默认 30 会插帧）。用户 2026-10-02 去掉了 Topaz creative（5 秒十分半钟）和 Bria（只能 2x、提升不明显） |
| 目标 | 按**短边**：1080p / 1440p / 4K（`FalUpscaleTarget`），和导出的分辨率档位一个口径。源的短边不比目标小就「没什么可升的」 |
| 倍数 | 目标短边 ÷ 源短边，再按模型认的范围夹：Topaz 1–4、FLUX 1.5–3、字节 1.1–10（`FalUpscaleTier.plan`）。夹过之后输出可能够不到目标（360p 送 Topaz 要 4K 只到 1440p）或超过（1344×768 送 FLUX 要 1080p 出 2016×1152）：**估价和界面都按夹过的输出尺寸算**，不按目标 |
| 请求体 | `FalUpscaleTier.body`：字段名和取值从接口定义快照来（`checks/Fal/schemas/topaz__upscale__video__precision.json` 等四份），自检逐条对着验；倍数按小数原样传（1.40625 正好 1890×1080） |
| 估价 | `FalUpscalePricing`，规律是 19 条的账单量出来的：字节按输出秒分档（1080p $0.0072、2K ×2、4K ×4；pro ×10），分毫不差；FLUX 按输出百万像素·秒线性（precise $0.0715、creative $0.1001）；Topaz 按网页「每 10 秒」价折成每秒、**向上取整到 $0.10、最少一档**（precision 1080p $0.20、4K $0.60；generative $1.20 / $2.60；没有 2K 档，1440p 按 4K）。Topaz 实收约是它的一半，账户没有折扣（`percent_discount` 0），差在网页标题价和 fal「credits 每任务取整一次」的规则没公开。**估价只许比账单高或相等** |
| 实际扣费 | `FalClient.billingEvents(requestIDs:since:)` 查 `GET https://api.fal.ai/v1/models/billing-events?start=…&request_id=…`，`FalBilling.events` 解析，`cost_total` 是实收；多数几分钟内出现。**要 ADMIN 权限的 Key**，只有 API 权限会 401 / 403，调用方当作查不到、照旧显示估价 |
| 上传 | 视频不能当 data URI 内嵌：`FalClient.upload(fileURL:contentType:fileName:onProgress:)` = `POST https://rest.fal.ai/storage/upload/initiate?storage_type=fal-cdn-v3`（带 Key）拿 `upload_url` / `file_url` → `PUT` 到 `upload_url`（**不带 Key**，那是存储桶的签名地址；**文件流着发**：`uploadTask(with:fromFile:)`，不整个读进内存 —— 整个原片直接上传时可能是几个 GB；字节进度从任务代理来，见第十三节）→ `file_url` 填进 `video_url`。旧文档的 `storage_type=gcs` 2026-10 起被拒（400 Invalid storage type）。`rest` / `api` 两个地址和队列地址一样是 `FalClient` 的构造参数，自检用假 URLSession |
| 等多久 | 视频一律 25 分钟（`FalUpscaleTier.maxSeconds`） |
| 维护 | `scripts/fal-models/refresh.sh` 也扫 `FalUpscaleModels.swift` 里的端点、目录按 video-to-video 列；改档位 / 改价同步这一节和自检 |

换源在 [工程文件与素材重链接](video-edit-project-file.md)「四之五」，任务那一层（范围、裁一段、封回原声、落盘、进度、账）在 [视频 upscale](video-upscale.md)；界面是第四刀。

## 十三、进度：AI 从 `get_job` 看、用户从编辑器顶上的状态行看（2026-10-02 起）

> 用户 2026-10-02 定：送 fal 的活（upscale、`generate_media`）在上传和生成中都要看得见进度。改 `FalJobPhase.swift`、`FalTransfer.swift`、
> `FalStatusRows.swift`、`AIJobs.liveDetail` 之前必读。

| 决定 | 口径 |
| --- | --- |
| 阶段是一份（`FalJobPhase`，纯值） | 六步：`preparing`（裁一段 / 把关花钱、取 Key）→ `uploading`（带字节比例）→ `queued`（带排队位置）→ `processing` → `downloading`（带字节比例）→ `finishing`（封回原声、落盘）。upscale 六步都走；`generate_media` 没有上传（图是内嵌的）。`FalJobProgress` 再记这一阶段从什么时候起（换比例不重记、换阶段才重记）和这一档通常要几秒 |
| **fal 处理中没有百分比** | 队列接口只给 `IN_QUEUE`（带 `queue_position`）和 `IN_PROGRESS`，日志里的步数各模型格式不一，**不能当百分比**。能给的就是阶段、排队位置、这一阶段已用的秒数、这一档的典型时长 —— 「处理中 48 秒，这档通常约 1 分钟」，**不画假进度条** |
| 典型时长 | upscale 每档一个数（`FalUpscaleTier.typicalSeconds`：2026-10-02 实测含排队，precision 70 s、generative 190 s、FLUX precise 120 s / creative 200 s、字节 standard 140 s / pro 320 s），面板上的「about N min」和进度里的「usually about N min」都从它算（`FalJobProgress.minutes`，不满一分钟算一分钟）；`generate_media` 按种类（`FalModel.Kind.typicalSeconds`：图 10 s、音效 5 s、音乐 30 s、视频 120 s，和工具说明里写的一致） |
| 上传 / 下载的字节进度 | `FalTransfer`：上传 `uploadTask(with:fromFile:)` + `didSendBodyData`，下载 `downloadTask` + `didWriteData`（`didFinishDownloadingTo` 那一拍当场把系统的临时文件挪到成品旁边的 `.part` 文件，回调一返回系统就删它）；按 1% 一格、没变不报；服务器没说总长就不报比例；**成功时 `FalClient` 一定补报 1**，失败 / 拒绝不报 1。`URLSession` 只许出现在 `FalClient.swift` 和 `FalTransfer.swift`（`checks/fal-wiring.sh`） |
| 给 AI 的 | `AIJobs.Job.liveDetail`：跑着的任务可以给一份明细，`get_job` 只在 running 时并进去。fal 的两种任务给 `FalJobProgress.json`：`phase`、`queue_position`（排队时）、`transfer_percent`（上传 / 下载时，整数）、`phase_seconds`、`typical_seconds`（知道时）。工具说明里写明这几个字段，AI 看了「排队第 3 位」「这档通常 2 分钟」就不会每 30 秒问一次只会说「还在跑」 |
| 给用户的 | 编辑器顶上的状态行 `FalStatusRows`：挂在「AI 正在剪辑」那条横幅底下（mockup「Status row while upscaling」说的「复用编辑器那条状态行」），每个 upscale 任务（`UpscaleActivity.jobs`）和生成任务（`FalGenerationActivity.runs`）一行：做什么、四个阶段的小标（过了的打勾、当前的带百分比 / 已用时间 / 「通常约几分钟」、没到的灰着）、估价、停止；upscale 做完那一行 Compare… / Dismiss。生成任务做完 / 失败 / 取消就从行上消失（结局 AI 会告诉用户）。检查器那一节同一份文字（`FalPhaseText`）。只订阅两个小对象、不读工程；**没有任务时什么都不画、不醒**（性能场景里计数为零，所以它能挂在横幅底下而不动基线） |
| 不改的 | `generate_media` 的结果和落点、upscale 做完先弹对比窗口的流程、钱怎么问、Key 怎么读 —— 这一节只加进度 |

回归：`scripts/check-fal.sh` 第八组（阶段、进度账、get_job 的字段、典型时长折成的分钟数、同一阶段同一比例只报一次）和第五 / 七组
（下载 / 上传的比例只升不降、成功最后是 1、失败不报 1、不留 `.part`）；`scripts/check-upscale.sh` 第五组（流水线的阶段按顺序、上传 / 下载报到 100%）；
`checks/fal-wiring.sh` 第 2、9 条（传输只经 FalTransfer、上传 fromFile、liveDetail 接到 get_job、任务登记进 FalGenerationActivity、横幅底下挂着状态行）。
人工：真 Key 做一次 upscale，状态行上「Uploading 35%」真的在走、排队位置变、处理那一格每秒走、下载百分比、做完 Compare…；
AI 用 `generate_media` 做一段视频时 `get_job` 的 `phase` 从 queued 到 processing 到 downloading，状态行同步。

