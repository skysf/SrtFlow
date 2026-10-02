# AI 接口（MCP）：让 AI 客户端调用 SrtFlow 剪辑

> 已生效的长期约束。产品决定、每一条拍板和理由见 [MCP 方案](../plans/2026-09-27-mcp.md)
> （推翻哪一条之前先读它为什么这么定）。这里写「只能这样做」的东西和人工回归清单。

## 一、结构：三段，活只在 App 里做

```
AI 客户端 ──(MCP：stdio，一行一条 JSON)──▶ srtflow-mcp ──(Unix socket)──▶ SrtFlow（AIToolRouter → AI*Tools）
```

| 部分 | 在哪 | 管什么 |
| --- | --- | --- |
| `SrtFlowMCPKit`（库） | `Sources/SrtFlowMCPKit/` | MCP 协议（`MCPServerCore`）、工具清单（`MCPToolName` + 三个说明文件）、选项词表、通道格式与 socket 收发。只依赖 Foundation，小程序和 App 共用 |
| `srtflow-mcp`（小程序） | `Sources/SrtFlowMCP/`，打包进 `SrtFlow.app/Contents/Helpers/` | 客户端按配置启动它。握手和工具清单当场回，工具调用转给 App；App 没开就 `open -g` 拉起来 |
| App 这一头 | `Sources/SrtFlow/AI*.swift` | `AIBridgeServer` 听 socket → `AIToolRouter` 排队、摆出剪辑页、记这一轮 → 各组工具 |

1. **工具清单只有一份**（`MCPToolName`）。小程序回清单读它，App 分派也 switch 它 —— 两边都是穷举，
   加一个工具漏了哪一边编译不过。**清单必须由小程序给**：Claude 一启动就要清单，不能为了列清单把
   SrtFlow 拉起来。
2. **选项词表**（转场、滤镜、文字动画、画面比例、帧率、分辨率）小程序拿不到 App 的类型，只能在
   `MCPVocabulary` 里抄一份 —— 抄的就会漂，`scripts/check-mcp.sh` 逐项和 App 的 `allCases` 对账。
3. **说明文字用英文，一个汉字都不夹**（模型读英文最准；AI 回用户时用用户的语言；2026-09-30 用户定：中文占 token，
   连「剪辑风格」「嗯、呃」这类举例也换成英文说法，`checks/MCP/CatalogTextChecks.swift` 扫总说明和整份清单）。每条写清：做什么、不传的参数怎么办、
   什么时候会回 `needs_confirmation`。所有工具共用的规矩写在 `MCPInstructions`（客户端会放进模型的上下文），
   其中一条是**只用 SrtFlow 的工具干活**：不拿别的程序（ffmpeg、脚本、终端）裁切 / 转码 / 复制 / 转换素材，不从网上
   下载素材，缺什么能力就告诉用户（方案第 31 条；2026-09-27 实测 Claude Code 拿用户自己 Homebrew 的 ffmpeg 转了副本、
   用 curl 下了配乐）。看画面用 look、量声音用 listen、改画面用 edit_clip —— 这三样补齐之后，这条规矩才站得住。
4. **stdout 只许写 MCP 消息**，一行一条，字符串里的换行必须转义（`JSONValue.encodedData` 就是这么写的）。
   调试输出写 stderr。
5. **工具不按个数卡，守三条**（方案第 33 条，2026-09-28 用户拍板；原来的「最多 40 个」撤了）：
   - **不许有两个长得像的工具**：加工具之前先看现有的加一个参数行不行（第四块的画面识别做成 `look` 的参数就是这样）。
     用途挨着的只能是一个只读、一个会改的（`transcribe` 只读、`generate_subtitles` 改字幕轨），说明里写清彼此的区别。
   - **只读的和写文件的不放进同一个工具**：客户端按 `readOnlyHint` 分组放行（Claude 桌面版分「只读 / 写入」两类，
     Codex 的 `writes` 模式也按它判），混在一起就只能按最严的标。
   - **说明总长度有上限**：整份工具清单（`tools/list` 的 JSON）7.2 万字符以内，约 2 万 token（2026-09-28 是 5.4 万）。
     上下文跟着说明总量走、不跟着个数走（合并工具省不了多少），用户那边还开着别的 MCP。超了先把说明写短。
     `checks/MCP/ProtocolChecks.swift` 钉着。
6. **按客户端怎么读来写：总说明是目录**（2026-09-30 用户拍板，[案例](../bugfixes/2026-09-30-mcp-text-truncated-at-2048.md)）：
   - **Claude Code**（默认开 tool search）会话开始只加载**工具名 + 总说明**，每个工具的完整定义用到才搜出来加载（一次最多 5 个）。
     它**只保留总说明和每个工具说明的前 2,048 个字符**（JavaScript 的字符串长度，超了截掉、末尾加「… [truncated]」，对模型和用户都不提示，
     只在它的 MCP 日志里记一行；参数的说明目前不截）。**Codex** 要求总说明的前 512 个字符自成一体。Codex 和 Claude 桌面版没有按需加载，整份清单每轮都进上下文。
   - 所以给 AI 的文字分三层，各管一件事：
     ① **总说明 = 目录**：SrtFlow 是什么、平常的顺序、几条要 AI **主动**做的规矩（开头问一次看着剪还是后台、只用 SrtFlow 的工具、
     只用给的文件、没存过的工程存在哪要告诉用户），和按需求分组的工具名（带上用户会说的词：9:16、水印、配乐……）。
     ≤ 2,048（配了 fal 拼上那一行也一样）；前 512 字就是完整的最短用法；**清单里每个工具名都要在目录里**
     （Claude Code 开搜之前只知道目录里写的）。
     ② **每个工具的说明 = 那一章**：这个工具怎么用，≤ 2,048；只跟某个参数有关的长话写进那个参数的说明（参数说明随工具一起加载）。
     ③ **出结果那一刻才用得上的规矩写在结果里**：`needs_confirmation` 的 `next_step`、任务结果的「用 get_job 等」、
     用户按了停止回的那句、`waiting_for_user` 的原话。
   - 往总说明里加东西之前先问：它是不是要 AI 主动去做？不是的话放进工具说明或者结果。
   - 守卫：`checks/MCP/CatalogTextChecks.swift`（总说明和每个工具说明 ≤ 2,048、前 512 字点到 open_folder / get_timeline /
     look / export_video、目录里有清单的每个工具名、只用英文）。

## 二、协议：两代客户端都要接

2026-07-28 版 MCP 去掉了握手（[变更记录](https://modelcontextprotocol.io/specification/2026-07-28/changelog)）。
小程序是「dual-era」：按客户端怎么开口决定说哪一代。

| | 老一代（2025-11-25 及更早） | 新一代（2026-07-28 起） |
| --- | --- | --- |
| 开口 | `initialize`（带 `protocolVersion`、`clientInfo`） | 每个请求 `_meta` 里带 `io.modelcontextprotocol/protocolVersion` 和 `clientInfo`；可先调 `server/discover` |
| 版本 | 客户端要的认得就照回，不认得回我们最新的老一代版本 | 不认得回 `-32022`（`UnsupportedProtocolVersionError`，`data.supported` 列出两代全部版本） |
| 结果 | 原样 | 每个结果加 `resultType: "complete"`、`_meta` 里的 serverInfo；清单类再加 `ttlMs` / `cacheScope: "private"` |

- 支持的版本写在 `MCPServerCore.legacyVersions` / `modernVersions`。新版协议发布后先看变更记录，
  把新版本加进去、补自检，**别只改版本号**。
- 工具自己的失败是**工具结果**（`isError: true` + 一句话），不是协议错误：模型要看得见、能转述给用户。
  只有「没有这个工具」「没有这个方法」「解析不了」才回 JSON-RPC 错误（-32602 / -32601 / -32700）。
- JSON-RPC 的 id 原样回（整数回整数，不能回成 `7.0`：有的客户端对不上号）。

## 三、通道：小程序 ↔ App

- **一次调用一条连接**：连上 → 写一行请求 → 读一行回答 → 断开（`MCPBridge.Request` / `Response`，带通道版本号，
  对不上时 App 回一句「请重启 AI 客户端」）。客户端并排发几个调用也不用在一条连接上配对。
- **socket 按 bundle id 分开**：`~/Library/Application Support/<bundle id>/mcp.sock`（路径超过 103 字节退到
  `/tmp`，用 FNV 哈希区分 —— **不能用 `hashValue`**，每个进程的种子不同，两边算出两个路径）。测试版和正式版
  同时开着各连各的。目录 0700、socket 0600，连进来的再用 `getpeereid` 核一次用户号。
- **还有人在听就不抢**：`MCPUnixSocket.listen` 先试着连一下，连得上说明同一个 App 开了两份，后开的那份不删
  前一份的 socket（删了等于把正在用的那份掐断）。
- **阻塞收发只在自己开的 `Thread` 上**，不进 Swift 并发的协作线程池（同
  [阻塞的媒体读取](blocking-media-reads.md)）。那条线程用信号量等主线程做完，它本来就是专门等这件事的。
- **小程序找 App**：从自己的路径往上找 `.app`，读它的 bundle id 算 socket；连不上就 `open -g -a <那个 App>`
  （不抢前台），最多等 45 秒。测试用的环境变量：`SRTFLOW_MCP_SOCKET`、`SRTFLOW_MCP_NO_LAUNCH`、`SRTFLOW_MCP_APP`。

## 四、工具在 App 里怎么做（每一条都是约束）

1. **一个工具 = 一步撤销。** 规则写成 `TimelineState` 上的纯函数（`AITimelineEdits`、`AIClipEdit`、
   `AISubtitleEdits`），在副本上算好、出错就抛，然后 `project.perform { $0 = next }` 一次提交：撤销登记、
   磁吸收尾、预览重建都走原来那条路。**而且每个改动工具都包在 `AIUndoGrouping.step` 里**：撤销管理器按
   用户事件分组，AI 的调用不是事件，不显式分组的话所有步堆进同一组、⌘Z 一按全退；也不许去手动关它自动开
   的那一组（下一次登记会抛异常、App 闪退）。包的那一段必须同步（没有 await），见
   [案例](../bugfixes/2026-09-27-ai-edits-share-one-undo-group.md)。新加改动工具时，照路由里那几个的样子包上。
   **一次调用里的每一次登记都要在同一个 step 里**：漏一处在外面（`add_clips` 以前先挂字幕、再进 step 放素材），
   它按事件自动开的组在后台关不上，之后每个 step 都嵌进去，撤一步全退；不是用户事件引起的**异步落账**（生成字幕、
   翻译写回、静帧转换失败删占位块、AI 的定格）也各包一层（[案例](../bugfixes/2026-09-27-ai-undo-swallowed-by-subtitle-attach.md)，
   `check-mcp.sh` 钉着）。
2. **能复用手动操作的全复用**：放素材走 `mediaImportLandings` + `insertImported`（撞上了往上抬一轨），
   切走 `split(clipID:at:)`，转场能不能放问 `transitionCapacity`，删和 ⌫ 同一口径（链接开着带上伙伴），
   素材 → 片段走 `clip(for:)`，生成 / 翻译字幕走面板上那同一个任务，导出走 `VideoEditExporter`。
   AI 多出来的只有两条：**给绝对值**（改入出点时起点不动；拖把手则是连起点一起挪）和**V1 往后推 / 往前拉**
   （`insert`、`ripple`，只动 V1 和它们的链接伙伴；别的轨、文字、滤镜、字幕由「联动」开关决定跟不跟 —— 开着（默认）压在挪动 /
   删掉的 V1 片段上的东西跟着挪 / 删（`perform` 收尾统一做，[联动](timeline-linkage.md)），写进了 delete_items / freeze_frame 的说明，
   `get_timeline` 报 `linkage`、改动的结果带 `linkage: {moved, deleted}`）。
   同一次 add_clips 里两段都点名「新开一条轨」时第二段放进第一段开的那条；**只认点名要新开的**，前一段只是因为还没有
   音频轨才开了 A1，不算（[案例](../bugfixes/2026-09-28-new-audio-lands-on-a1.md)）。
3. **排队**：改工程的调用按到达顺序一个接一个做（`AIToolRouter` 的 `tail`）。Claude 会在一条消息里并排发
   几个调用，不排队的话「接在 V1 最后」看谁先探完素材。`get_status` / `get_job`（最多等 30 秒）/ `cancel_job`
   不排队。
4. **看得见**：改工程之前 `AIEditorPresenter.prepareEditor` —— **只在一轮的第一步**切到剪辑页、主窗口
   `orderFrontRegardless`（摆到最前面但**不激活 App**，键盘留在用户打字的对话框里）；这一轮中途不再摆
   （方案第 32 条：一步一跳会盖住用户正在别的 App 里用的窗口，点进 SrtFlow）。用户中途挪别的窗口上来、
   最小化、切栏目都照他的来；只有窗口被关了才开回来、剪辑页从没出现过才切过去。然后等剪辑页把窗口的
   撤销管理器交给工程（没有它 AI 的改动进不了 ⌘Z）。每一步之后 `reveal`：选中改到的、播放头跳过去、
   时间线滚到看得见（不动窗口）。AI 从不移动鼠标、不模拟按键。
   **后台模式**（`set_view`，方案第 7 条）：一次都不摆窗口、`reveal` 不选中不挪播放头（`seek` 例外：AI 就是要给用户看
   那一刻）；改动照样进工程、照样一步撤销。总说明要求 AI 一次对话问一次「要看过程还是后台直接出结果」（用户说了就不问）。
   这次运行里一直有效，App 重开回到看得见。
5. **不许弹模态框。** 用户在对话框那边，看不见也点不着，调用就一直挂着。「当前工程从没存过、又剪了东西」
   的时候 AI 要打开 / 新建别的工程：先把它存进 `SrtFlow/工程`（撞名加编号）再换，结果里写 `previous_project_saved_to`
   （原来那条路就不会弹了；方案第 34 条：不问也不丢）。
6. **只有删文件才问**（方案第 34 条，2026-09-28 用户拍板：「少问几次，越少越好。核心就是删除文件需要问」）：
   - 删进废纸篓先问（`AIFileTools`）。
   - 读点名文件夹以外的文件**问一次**，同意了就记住那个文件夹（`AIReadGrants`：含子文件夹，重启也记得，设置 → AI 里
     列出来、能删）。文件夹太大（根目录、顶层文件夹、卷的根、个人文件夹本身）时只记那个文件 —— 不然同意读一个文件
     就放开了整个家目录。问题里写明「同意之后记住这个文件夹」。
   - **从不覆盖**：导出、新建、另存撞名都加编号（`ExportFileName.unoccupied`），所以不问；AI 要替换旧文件就先用
     `manage_files` 把它删进废纸篓（会问）。
   会回 `needs_confirmation` 的只许这两处（`AIFileTools`、`AIWorkspace.confirmReading`），`scripts/check-mcp.sh` 扫描钉着。
   `AIConfirmations` 发的令牌绑着具体那件事（`action` 字符串），一次有效、十分钟过期，换一件事拿它来不认。
   时间线上的改动一律不问。
7. **长任务回任务号**（客户端对一次调用大多只等一分钟）。结局在任务结束的**那一刻**记下（导出挂在
   `isExporting` 变回 false 上 —— `@Published` 在赋值前发，那时成品路径 / 错误已经写好；导出的结果带 `audio_loudness_lufs`、
   `audio_peak_dbfs`（限幅前），混音过了 −1 dBFS 被限幅器压过的还带 `audio_limited_seconds`、`audio_max_reduction_db`，压过 3 dB 的再带
   一句 `note` 叫 AI 用 `set_track master volume_db` 压下去再导，[成片的声音](export-audio-mixdown.md) 第二节第 3 条；生成字幕挂在 `stage`
   上并且 `dropFirst`，订阅那一刻发的是上一次任务留下的结局）。AI 指定的分辨率只用于这一次
   （`settingsOverride`），不写回用户在面板上记住的设置；压缩 / 烧录同理（第 24 条）。
   送 fal 的任务（`generate_media`、upscale）跑着时 `get_job` 带阶段：`phase`（queued / processing / downloading…）、`queue_position`、
   `transfer_percent`、`phase_seconds`、`typical_seconds`（`AIJobs.Job.liveDetail`，[fal.ai 生成](fal-generation.md) 第十三节：fal 处理中没有百分比，
   给的是阶段 + 排队位置 + 已用时间 + 典型时长）。
   **任务在等用户动手时必须说出来**：结果和 `get_job` 里带 `waiting_for_user`（总说明要求 AI 立刻转告），
   SrtFlow 顶上的提示条同步显示。现在只有一种：翻译缺语言、macOS 弹下载框（只能由用户点，苹果不给静默下载）——
   这时把 SrtFlow **激活**、主窗口摆到最前面（AI 接口里唯一故意抢前台的地方），并由 `AIDownloadWatch`
   每两秒问一次系统真实状态（系统框的进度条会停）。翻译的原文语言**按字现判**（`AITextLanguage`），
   不信工程里记的旧语言（AI 会整轨改写原文）。见
   [案例](../bugfixes/2026-09-27-ai-translation-stale-source-language.md)。
8. **AI 看不见画面**，所以结果里替它量：`set_text` 按成片的画面排一次版，回几行和文字块在画面上的位置
   （`block`：左、上、右、下的比例）；有词被从中间折断（拼音文字的两个字母之间）、或者文字块出了画面（按预览
   选中框那一份版面框量，写明哪条边出去几像素），各给一条提示让它改（`AITextFit`；2026-09-27 竖屏 110 号的
   「Antarctica」被折成两行，同一天冒烟 130 号的「南极探险」折成两行顶出了上沿）。以后加的画面类工具同一个思路：
   能量的就量出来回给它；量不出来的让它用 look 看。
9. **短 id**：UUID 前 8 位，撞了整体加长；收的时候前缀唯一就认。**轨道名** V1 = 主轨、V2… = 上层视频轨、
   A1… = 音频轨，和专业剪辑软件同一套叫法。
10. **AI 做出来的文件**放在起点下面的 `SrtFlow/导出`、`SrtFlow/工程`（名字跟着 App 语言）。起点只有一条规则
   （`DefaultFolder`，手动的打开 / 存储为面板、导出面板第一次用的位置也用它）：点名的文件夹 → 工程的家 →
   「下载」，**没有「影片」**（2026-09-27 用户拍板）。工程的家一般是工程文件所在的文件夹，AI 存在
   `X/SrtFlow/工程/` 里的是 X —— 不然下一次的成片会进 `X/SrtFlow/工程/SrtFlow/导出`，读 X 里的素材也要多问。
   **AI 改了一个从来没存过的工程，改完马上存进 `<起点>/SrtFlow/工程`**（`saveIfNeverSaved`，撞名加 2、3，
   不覆盖也不问），结果里带 `project_saved_to`，之后交给自动保存；手动剪的未命名工程照旧等用户存 —— 除非 AI 要打开 / 新建别的工程：
   那时先用同一个办法存下来再换（`saveUntitled`，第 5 条）。
   `open_folder` 不列根上的 `SrtFlow/`，免得把上次的成片当素材。
11. **画面怎么放（`edit_clip` 的 fit / crop / x / y / scale，方案第 31 条）**：只改这一段的 `crop` 和 `placement`，
   **从不改素材文件、不出副本**。规则在 `AIFrameFit`（纯值）：
   - **铺满（fit=fill）= 源画面上一扇和画布同比例的窗正好映到整幅画布**。先用裁切收（每边最多 0.45，
     `ClipCrop` 的上限），收不下的交给摆放框（把裁剩的画面放大、挪到窗对上画布，框的中心可以在画布外）。
     裁切一次收得下时摆放框就是默认布局、存 nil —— 检查器里看到的只是一个裁切。16:9 转 9:16 焦点偏在
     一边时只靠裁切做不到（右边要裁 0.68），这是两样一起用的原因。
   - **完整显示（fit=fit）**：裁切 = 可用区域，摆放回默认。fit 从整幅画面起算，除非同时给了 `crop`。
   - **按位置和大小（x / y / scale）**：scale 相对默认布局（1 = 裁剩的画面完整放进画布）；只改裁切时中心和
     大小不变、宽高比跟着裁剩的画面走（不拉变形）。
     **中心能到 −2…3**（`AIFrameFit.centerRange`，2026-09-29 验收实剪：放大的幻灯片只看得到中间）：画面比画布大时中心要出到 0–1
     外边，画面的边才够得到画布的边（16:9 铺满 9:16 是 3.16 倍，0–1 只看得到中间那六成多）；scale 最大 6，所以 −2…3 够到任何一边。
     位置关键帧同一个范围。工具说明（edit_clip、set_keyframes）里的范围和它对账（`FramingChecks`）。
   - **去黑边（remove_black_bars）**：从这一段用到的那一截里均匀抽 5 帧（`AIFrameSampler`，小图），`AIBlackBars`
     找四边连续的黑行 / 黑列（最亮的点 ≤ 40、平均 ≤ 20），**几帧合起来每边取最小**：只要有一帧那儿不黑，那儿
     就不是黑边（夜景的暗天不会被当成遮幅）；整帧都黑的帧不算数；遮幅里压着字幕的扫到字就停。找到的黑边
     当作「可用区域」：单独用就是裁掉它，配 fit / fill 就在它里面算。看到什么写进结果（`black_bars`）。
   - **铺满时对准主体（focus 默认 subject）**：窗不用裁（素材和画布同比例）就不去认；要裁时抽 5 帧，用 macOS 自带的
     Vision（`AIVision`）认人脸 → 人（上半身）→ **字多时对准字**（幻灯片、录屏，第 37 条）→ 显眼的东西（注意力显著区），
     `AISubjectFocus` 按帧挑点（几张脸放得进
     窗就对准合起来的中心，放不进对准最大的那张）、几帧取中位数；主体在这一段里走动超过半扇窗时结果里带一句
     提醒（固定的窗跟不住，建议切开分别铺）。认不出来就照正中铺。focus_x / focus_y 直接给点、focus=center 跳过认。
     Vision 的 `perform` 同步卡线程，在 `MediaReadQueue.analysis` 上跑（[阻塞的媒体读取](blocking-media-reads.md)）；
     它的框是左下原点，换成左上原点只在 `AIVision.topLeft` 一处。
   - 「约等于默认就存 nil」只有 `PlacementDefault` 一处（半个输出像素，检查器写摆放也走它）。
   - 位置 / 大小做了关键帧的段不改（静态摆放会被关键帧盖掉），报错请用户先删关键帧。
   - `edit_clip` 分两步：`AIClipTools.plan` 可以 await（要看画面的在这一步抽帧、识别），`apply` 同步提交、
     包在 `AIUndoGrouping.step` 里；中途画布变了（用户换了画面比例）就不提交、请 AI 重来。
   - 读回来：`get_timeline` / `edit_clip` 的结果里每段画面带 `picture`（`fills_frame`，非默认时 x / y / scale / crop）；
     默认布局又正好盖满的段不写，省 token。
12. **看（look，方案第 31 条）**：AI 看不见画面，就给它看。两种看法、一次回一张图 + 每帧一段文字：
   - **时间线**（不给 file）：成片在那一刻的样子。`AIFrameComposer` 按预览的层序合成 —— 视频轨（自己调
     `VideoEditCompositionBuilder.build`，**不借播放器上挂着的那份**：AI 刚改完就看时，预览的重建可能还在防抖里）→
     滤镜（预览那串 `FilterStack.ciFilters`）→ 形状（导出那份 PNG）→ 文字（`TextRenderer`，时刻先 `quantize`）→ 字幕
     （预览那个 `BurnInSubtitleOverlay`，`ImageRenderer` 离屏按画布像素渲）。**每一层调现成的那一份，不另写**。
     每帧另附「画面上有谁」：看得见的片段和轨、文字、字幕。
   - **素材文件**（给 file）：挑镜头用，`AIFrameSampler` 抽帧（`MediaAssetCache` 的素材、async 取帧不卡线程）。
     点名文件夹以外的文件先问。
   - 几帧拼成一张（`AIContactSheet`：试每种列数挑最接近 4:3 的、最后一行至少半满、竖画面整张不高过宽的 1.25 倍，
     每格左上角标时刻），JPEG，跟在文字后面作为 MCP 的 `image` 内容回去（`AIToolResult.images`）。一次只回一张：
     几张分开的图每张单算 token。
   - 每帧的文字（`AIFrameDescription`）：Vision 的标签（前 6 个、把握 ≥ 0.3；**只是粗猜**，AI 生成的、少见的画面常认错 ——
     2026-09-29 验收里潜水员认成水母、冰面航拍认成地图，工具说明叫 AI 以画面为准）、人脸框（大的在前）、人数、主体、
     画面上的字（accurate + 自动判语言，**连同它的框**，最多 6 块）、平均亮度、黑边。看不了图的模型传 `image=false` 只拿文字。
   - 只读：不改工程、不挪播放头、不摆窗口；排队（刚发的改动先做完再看）。
13. **听（listen，方案第 31 条）**：AI 听不见，就把声音量给它。数据是画波形那一份（`WaveformStore`，一个文件读
   一遍，峰值 + 顺手攒的均方，见 [波形与深度缩放](audio-waveform.md)），**不另读 PCM、不起 ffmpeg**。`AIAudioLevels`
   （纯值）：
   - 窗和均方桶的边对齐（两桶一窗，48kHz 约 43ms）：不对齐的话跨在「响 / 静」交界上的桶会把能量摊进隔壁的静音窗，
     静音段两头各缩一截。
   - **电平只算有声音的部分**（静音窗不进平均：一段话停顿多，整段平均会被拉低，AI 配音乐会配得太响）；dB 走
     `AudioGain.decibels`（电平表也是它，−60 = 静音或更轻）。
   - 片段 = 成片里听到的：窗换成时间线秒，乘 `EditClip.heardGain`（段音量 / 曲线、渐入渐出、轨道推子；波形条画
     「听到的声音」也是它）。静音、藏起来的段、藏起来的轨不量（量出来的数会让 AI 以为它在响）。
   - 三种问法：一段（带静音段列表和响度曲线）、一个文件、整条时间线（每段一行，只给静音段个数）。一次最多等波形读
     40 秒，没读完先把读到的给出去、说一声再调一次。

14. **读文稿（read_document，方案第 22 条）**：用户给的讲稿、大纲、卖点清单读成文字（`AIDocumentReader`）：PDF 用 PDFKit，
   Word / RTF / ODT 用系统的富文本导入，txt / md 按 [用户文本文件的编码](text-file-encoding.md) 读；Pages 和扫描件读不了，
   明说请用户导出 PDF / Word。整理换行和空行省 token，长文稿按 `from_char` / `max_chars` 分段读。读大 PDF 会卡线程，
   在 `MediaReadQueue.analysis` 上跑。点名文件夹以外的文件先问。`open_folder` 把 .txt 列成文稿（文件夹里的 .txt 多半是讲稿；
   当字幕用照样 `add_clips`）。

15. **整理文件（manage_files，方案第 23、24 条）**：移动、改名、建文件夹、删除进废纸篓，规则在 `AIFileOperations`（纯值）：
   **只在点名的文件夹里动**（不动文件夹本身、不往外挪）；**不覆盖**，撞名就报错让 AI 换名字；改名没写后缀沿用原后缀；
   **删除一律先问**（令牌绑着这一批文件）、只进废纸篓。只在用户开口让整理时才整理（写在说明里）。工程里用到的素材挪了、
   改了名，调 `revalidateMediaLocations` 按书签跟过去（和用户在访达里挪素材同一条路）。这些都不进 ⌘Z，结果里写明做了什么。
   界面上照样不做文件管理（AGENTS.md 工程原则 1）。

16. **访达选中（open_folder from_finder，方案第 22 条）**：用系统自带的 `osascript` 问访达选中了什么（`AIFinderSelection`）；
   选了一个文件夹就点名它、全列，选了几个文件就登记它们共同的上级、只列选中的（先扫全再挑，免得大文件夹里选中的在上限
   之外），什么都没选就用最前面那个访达窗口的文件夹。**Info.plist 必须有 `NSAppleEventsUsageDescription`**（中英文在
   InfoPlist.strings）：没有它 macOS 不弹「想要控制访达」、直接拒绝（`check-mcp.sh` 扫描钉着）。第一次要用户点「好」：
   等授权框时 osascript 不返回，等它的线程在 `MediaReadQueue.analysis` 上，最多等 50 秒，到点请 AI 让用户点完再来；
   用户拒绝（-1743）就告诉 AI 去系统设置哪儿开。边跑边读走输出（选中上千个文件时路径会超过管道的 64KB）。

17. **一段的其余设置（edit_clip，方案「分块」第 2 块的现有功能铺满）**：规则在 `AIClipDetails`（纯值），能调现成的都调 ——
   旋转 / 不透明度照检查器夹紧（±360°、0…1），**做了关键帧的那一行不改**（报错）；入场 / 出场的种类和时长成对改
   （`kind == .none` ⟺ 0 秒：只给时长当渐显、只给种类给默认 0.6 秒）；音量曲线给的是时间线秒、存成源时间，按音量线的容差
   去重，空列表去掉曲线；**有曲线时 `volume_db` 整条平移**（同检查器，[案例](../bugfixes/2026-09-27-ai-volume-ignored-on-curved-clips.md)）；
   声音场景走 `setSoundSceneKind / setSoundSceneValue`（检查器同一份），旋钮名按场景分（喇叭类 distortion / tone，
   空间类 room_size / distance），给错了报错；标记给整份列表，走 `EditClip.addMarker`（半帧容差，同按 M）。
   动画、场景、标记颜色的词表在小程序里抄一份，`check-mcp.sh` 和 App 的类型对账。`get_timeline` 带上这些设置（默认的不写）。

18. **轨道（set_track）**：推子走 `TimelineState.setTrackVolume`（夹紧只在那一处，轨道头的推子也是它），总推子照
   `setMasterVolume` 夹紧；藏整条轨给的是绝对值（界面上是按眼睛切换）。只认现有的轨，不开新轨。只动推子的改动由
   `perform` 自己走只换混音的快路径。`get_timeline` 的每条轨带 `volume_db`（非 0 dB 时）、顶层带 `master_volume_db`。
19. **关键帧（set_keyframes）**：规则在 `AIKeyframes`（纯值）。每样给一串（时间线秒, 值；或 `relative=true` 时片段的比例）整行换掉，存成源时间、半帧容差
   （和检查器打关键帧同一把尺）；位置 = 画面中心（0…1），大小相对默认布局（1 = 完整放进画布，存成宽、高两行，
   和 `edit_clip` 的 scale 同一把尺）。空列表去掉那一行、**静态值原样留着**（检查器「清除」会复位静态值，AI 不替它复位）；
   一行都不剩时 `animation` 回到 nil。位置 / 大小做了关键帧的段，`edit_clip` 的画面放法照旧拒绝（第 11 条）。
   **缓动**（2026-09-30）：`easing` 管这一次给的每一段（linear / easeIn / easeOut / easeInOut，词表和 `KeyframeEasing` 对账），
   没给一律 easeInOut（检查器手打的默认线性）；`get_timeline` 报的每个点末尾带那一段的曲线名。

20. **形状（set_shape）**：规则在 `AIShapeChange`（纯值），加新的或改已有的（只改给了的字段），夹紧照检查器 / 预览里拖
   的那一套（线宽 1…24、尺寸 0.02…1、线的角度 ±90°、至少 0.2 秒、中心 0…1），正方形高等于宽、只有线能转；新加的默认大小
   同检查器「加形状」。形状不进合成，提交不重建预览（同检查器）。`get_timeline` 列出形状（以前不列），删除走 `delete_items`。

21. **复制一份（duplicate_items）**：**不另写落点**，直接用 ⌘C / ⌘V 那两个纯函数（`TimelineClipboardPayload(copying:)` →
   `TimelinePaste.apply`），不经过系统剪贴板 —— 撞上往上抬一轨、几组保住上下关系、链接组换新号、换新身份全和手动粘贴一样
   （[复制粘贴](timeline-clipboard.md)）。AI 多出来的只有：按 id 分类（同 delete_items）、链接开着时带上伙伴（同 ⌘C）、
   不给落点紧接着这一批的结尾。静帧没转完的走 `convertPastedStills`（同 ⌘V）。

22. **定格（freeze_frame）**：和手动定格走同一个 `runFreeze`（准入、抽帧、PNG 放在工程旁边、提交前核对一样都不另写，
   [定格](freeze-frame.md) 末节）。AI 多给一个时长；抽帧转码要 await，所以把「提交那一下」交给定格去包：
   `project.freezeFrame(…) { body in AIUndoGrouping.step(undo, body) }`（`check-mcp.sh` 钉着）。不给 clip_id 时定格那一刻 V1 上的段。
   要收在一段的最后一帧上：定格点落在那一帧里，不到一帧的右半自动拿掉（[定格](freeze-frame.md) 第 4 节）；静帧后面还剩一截
   不到 1 秒的原片时，结果里带 `tail_id` 和一句「要收在静帧上就删它」（2026-09-29 验收实剪：AI 两次手动删尾巴）。

23. **音乐库（find_audio、add_clips 的 library_id）**：搜的是音频库那一页同一个函数（`AudioLibraryManifest.filter`：标题、
   艺人、中英文标签，几个词是「与」）；放上时间线和从音频库拖进来一样 —— 下载进缓存、带 `remoteKey`（清了缓存、换了机器
   也找得回来）、时长按清单、**不按工程总长裁短**，落点走 add_clips 那一套（同一个 `AITimelineEdits.place`）。
   声音比画面长时 add_clips 的结果里带一句（到哪、画面到哪、用 edit_clip 裁短淡出），不然 AI 过几步才发现片尾全黑（2026-09-29 验收：130 秒的曲子把片长拖到 130 秒）。
   署名和署名页同一个口径：句子原样用清单给的 `license.text`，CC0 以外都要署（纯值的 `AIMusicCredits`）；add_clips 的结果、
   get_timeline 的 `music_credits` 都带着，总说明要求 AI 做完告诉用户。get_timeline 里音乐库的段写 `library_id`、不写缓存里的
   路径。清单读失败过就再读一次（`loadIfNeeded` 失败后不会自己重试）；断网用上次的清单并说明。
   **音效库（2026-09-30，[音效方案](../plans/2026-09-30-sound-effects.md)）**：第二份清单 `Audio/SoundEffects/manifest.json`
   （`AudioLibraryStore.soundEffects`），`find_audio kind=music|sound_effect|any`（默认 any，两个库一起搜，同一个 `filter`）；
   按 id 找素材（library_id、重链接、署名）**两个库都看、不按 id 前缀猜**（`AudioLibraryLookup`：一个库读失败不拖累另一个，
   失败写进结果的 `warning`）；音效条目带 `hit`（入库时量的落点），`add_clips {library_id, hit_at}` 按它反算开头（同合成音效那条
   `AISoundEffectRequest.placement`，没落点的报错叫用 start）；音效段默认 −8 dB（`SoundEffectClipGain`，面板拖进来也一样）；
   授权 `owned` 不署名（只问 `AudioLibraryLicense.needsCredit`）。**AI 的顺序（用户定）**：先 find_audio 找录音、没有合适的用
   sound_effect 合成、真实声音都没有才 generate_media；工具说明、总说明、风格卡都这么写；别去网上下载。

24. **压缩、烧录字幕文件、转字幕格式（compress_videos、burn_subtitles、convert_subtitles）**：不开工程，直接处理文件。
   - 压缩和烧录**排进 App 里现成的那两个队列**（`EncodeQueue.compress` / `.burnIn`，和页面上点「开始」跑的是同一条管线），
     用户在那一页看得见、能取消；回任务号，`get_job` 等结局（每个成品的路径、大小、比原来小了多少；失败的带原因）。
     队列没有完成回调，`AIEncodeTools` 每半秒看一眼这一批，都跑完了（用户从列表里删掉的也算完）才记结局。
   - **底子是用户在那一页记住的设置**（[导出设置](export-settings.md) 第六节：队列创建时就读回来，页面没出现过也对），
     AI 给的四项（quality 三档、fast = 硬件编码、分辨率上限、帧率上限，换算在纯值的 `AIEncodeOptions`）**只用于它排的
     那几条**：存在条目自己身上（`EncodeItem.ownSettings`），跑的时候先用它；页面上改设置、改输出文件夹都不碰这些条目。
     烧录的字幕样式就是烧录页那一套，AI 不改。
   - **不替用户开跑**：`start()` 会把等着的条目一起跑掉，所以队列停着、里面有用户自己排了还没开始的，就不排，请 AI 转告
     用户先开始或移掉。同一个文件已经在队列里（没跑完）也不重复排。
   - 做出来的文件放 `<起点>/SrtFlow/导出`（第 10 条），名字是页面那套（`_compressed`、`_sub`），撞了加编号：硬盘上有的、
     队列里别的条目要写的、同一批前面用掉的都算撞 —— **从不覆盖，所以不问**。读点名文件夹以外的文件照样先问
     （`AIWorkspace.confirmReading`，读文件的工具都走它）。
   - 转字幕格式当场做完：读和转和批量转换页同一个函数（`SubtitleConverter.convertedContents`，编码只走 `TextDecoding`），
     写的时候 `.withoutOverwriting`。

25. **词级时间（transcribe，第 3 块的原始数据）**：转写和生成字幕是**同一套**（`TranscriptHarvester`：定语言含自动检测、
   备模型租约、按 2 分钟一窗转写、合进按素材指纹存的缓存），缓存也是同一份 —— 用户在面板上生成过字幕的素材，AI 不用再转。
   - 缓存已经覆盖要的区间就当场按句读出来；没覆盖就起任务（`TranscriptionTask.transcribeOnly`：只转写、不生成字幕、不碰工程，
     **和生成字幕共用一个串行槽** —— 两边同时跑会互相删临时目录、抢同一份缓存；跑的时候面板上照样看得见进度，结束阶段回
     idle），AI 用 get_job 等完再调一次来读。
   - **失败时给 AI 它能照做的话**（2026-09-29，[叫 AI 去面板里选语言](../bugfixes/2026-09-29-ai-told-to-pick-language-in-panel.md)）：
     自动检测没认出语言时检测处抛 `LanguageUndetectedError`（单独一个类型，不挂在只在 macOS 26 上有的 TranscriptHarvester 里），
     面板照旧说「去面板里选」；transcribe、generate_subtitles 的任务失败都经 `AIHarvestFailure`，换成「有人说话就带上 language 再调，
     没人说话就不用转」。以后界面上的报错要叫人去点哪儿的，AI 那一路都要这样换一句（check-mcp.sh 扫描钉着这两个任务）。
   - 按句读（`SpeechTranscript`，Core）：词归哪段、从哪儿开口和生成字幕同一份（`SubtitleSegmenter.placed`：说话中点落在
     片段里才算，停顿后面第一个词按估出来的开口）；成句同一个函数（`SubtitleBreaks.sentences`）；一句超过 40 个词再切，
     优先切在逗号后面。时间：片段是时间线秒（变速换算好），文件是文件里的秒；两位小数。
   - 一次最多约 12000 字，读不完回 `next_from`（`AITranscriptFormat`）；要逐词时每句带 [词, 开始, 结束]。
   - 默认转视频轨上所有带声音的画面段；配乐、音效这类纯声音的段要点名才转。语言给了就用它的缓存；auto 时先认这次运行里
     检测出来的，没有就看已装语言里哪份缓存覆盖了、词的平均可信度最高。缓存配置版本只有 `TranscriptSidecarStore.configVersion` 一个数。

26. **鼓点（listen 的 beats，第 3 块的原始数据）**：`AudioBeatTracker`（纯计算，Accelerate）：频谱通量**分六个频带各自按平均值
   归一再相加** → 起音强度的自相关挑速度（50–200 BPM，偏向 120 附近）→ 动态规划跟拍（Ellis 2007）→ 四种相位里起音加起来最强的
   当小节头。不分频带时宽频的踩镲压过底鼓，拍子会被拉到后半拍上（合成鼓组实测：128 BPM 每拍差半拍）。最强的那 0.5% 起音
   不到中位数的 3 倍就当没有节拍（长音的相位和分帧错开会造出假拍子）；可信度低于 `clearConfidence`（0.3）照给但说一句，
   cut_to_beat 不踩。读采样在 `AIBeats`：11025 Hz 单声道、读的循环是单独的同步函数、在 `MediaReadQueue.analysis` 上跑，
   按「路径 + 大小 + 修改时间 + 区间」记在内存里；时间从读出来的第一帧算（读取器的起点会对齐到包边界）。片段的拍换成时间线秒、
   速度乘播放速度；文件是文件里的秒；一次最多分析 15 分钟。**分析的区间是整首歌**（`BeatAnalysisWindow`，2026-09-29）：
   请求落在文件开头 15 分钟里就分析整段，listen 和 cut_to_beat 各按自己的区间挑拍 —— 各分析各的那一段时，6/8 拍的歌一边
   63.5 BPM 一边 95.3，切点比重拍晚 0.3 秒（[案例](../bugfixes/2026-09-29-beat-analysis-window-differs-between-listen-and-cut-to-beat.md)）。

27. **按文字剪、删停顿和口头禅（cut_speech，第 3 块的智能剪）**：只对 V1 上的口播片段。要剪掉的几截（`AISpeechCuts`，纯值）：
   AI 点名删的 / 只留的（时间从 transcribe 来）、比 `remove_pauses` 长的停顿缩到 `pause_left`（停顿是画波形那一份数据按窗量，
   门限没给就从这一段自己量：底噪往说话走 35%、夹在 −60…−30）、口头禅（英中日常见的几个，按整个词认）、说重了的词（一两个词
   紧接着又说一遍，剪前面那遍）。口头禅和重复词要转写，没调过 transcribe 就报错；按文字剪没有转写也能剪，只是切口不挪。
   - **切口落在词和词之间空隙的中点**，离词最多 0.3 秒；一个词归哪边按它的中点判（识别器给的相邻两个词会重叠几毫秒）；
     一刻已经落在空隙中间（AI 特意挑的静音处）就不动。合并时两刀之间剩不到 0.2 秒就连成一刀、片段头尾剩一点点也剪掉、
     对齐到工程帧、不到两帧的不剪。
   - 落到时间线上用手动那一套：从最后一刀往前 `LinkRegrouping.split` 切开、`AITimelineEdits.delete` 带波纹删中间那块，后面的
     V1 片段往前补；**链接的声音不管开关都跟着剪**（剪口播剪到画面和声音对不上，不会是 AI 想要的）。片段自己静音了、声音分离到
     音频轨上时，量停顿、读转写都用链接的那段声音。其他轨看「联动」开关（2026-10-02 起，[联动](timeline-linkage.md)）：开着（默认）
     压在剪掉那几块上的东西一起删、后面的字幕 / 文字跟着画面前移（`perform(deletesContent: true)`），关着才不动、结果里提醒 AI
     剪完重新生成字幕（有缓存，快）；`next_step` 按开关分两种说法。
   - 两步：`plan` 可以 await（量声音、读转写缓存），`apply` 同步提交、路由包 `AIUndoGrouping.step`（同 edit_clip，
     `check-mcp.sh` 钉着）；中途时间线变了就不提交、请 AI 重来。

28. **音乐踩点（cut_to_beat，第 3 块的智能剪）**：V1 上一串一个挨一个的片段（不点名就是和音乐同时在放的那一串），按一段
   音乐的拍子（或小节头）重排（`AIBeatCuts`，纯值）：第一段的开头不动，每段**只改出点**（入点不动），下一段接上 —— 不给拍数
   时每个切口挪到最近的拍，给了拍数每段正好那么多拍（素材不够长用放得下的最多拍数）；至少 0.4 秒；一拍都放不下、音乐放完了的
   保持原长并在结果里说。落到时间线上：链接的声音跟着挪、出点改同样多（不超出它自己的素材），这一串后面的 V1 片段按总长的
   变化整体挪；音乐和别的轨不动。拍子不清楚（可信度低于 `clearConfidence`）不踩，照实告诉 AI 换一首或手剪。
   拍点先对齐到工程的帧（`AIBeatCuts.onFrames`，同 cut_speech 的切口：落在两帧中间时预览和成片可能各取一边）。
   结果里每段的 `beats` 是这一段里头一拍到切口之间的拍子间隔数（`AIBeatCuts.beatCount`）：音乐自己的引子（第一拍前那一小截）
   不算一拍，每段 4 拍时第一段也回 4。两步 plan / apply，同 cut_speech。

29. **分镜头（look 的 shots=true，第 4 块的本机识别画面）**：一个视频文件（或时间线上一段用到的那一截）按镜头切换点分开，
   每个镜头取**中间那一帧**让 Vision 描述（和别的「看」同一份 `AIFrameDescription`），拼成一张每格一个镜头的图。
   - 切点（`AIShotDetector`，纯值）学 PySceneDetect 的自适应检测：画面缩到长边 48 像素，逐像素 RGB 差的平均当「变化」；
     一帧够大（≥ 0.06）又高出前后两帧平均 3 倍才算切（摇镜头、走动整串都在变，不算）；连着变、不到半秒的一串算一个转场、
     切在变得最多的那一帧；暗下去又亮起来在最暗那一截正中切；两刀至少隔 0.6 秒。叠化认不出来。
   - 扫描（`AIShotScan`）：整个文件从头解到尾，按「路径 + 大小 + 修改时间」缓存，同一个文件同时只扫一次。解码就是全部成本：
     M1 上 1440p 约 17 倍速，分段并行也不更快（硬件解码器只有一个）。读的循环在单开的 `MediaReadQueue.shots` 上，
     不占「看」要用的两条（[阻塞的媒体读取](blocking-media-reads.md)）。调用方最多等 20 秒，没扫完就回任务号
     （`AIJobs` 的 `shots`，get_job 看进度、cancel_job 能停），扫完的结果照样进缓存，再调一次当场就有。
   - 一页 24 个镜头，多了回 `next_from`。看文件时时间是文件里的秒（直接当 add_clips 的 source_in / source_out），
     看一段时是时间线秒、另附源秒（在那儿 split_clip 就按镜头切开）。
30. **一次看好几个文件（look 的 files）**：最多 24 个，视频取正中那一帧、图片就是它，每格标文件名；点名文件夹以外的文件
   这一批只问一次。素材A那种几十个小文件，AI 两次调用就看完（2026-09-28 冒烟：47 个镜头，Vision 的标签把企鹅、冰山、
   冰面和丛林、城市分得开；少数中间那一帧没有把握够的标签，要看图）。
31. **跟拍（edit_clip fit=fill 的 follow，默认开）**：铺满、对准主体时，主体走动大就让那扇窗跟着走（`AIFollowSubject`，纯值）。
   - 每秒抽两帧（至少 5、最多 30 帧）认主体；**只跟人脸和人**（「显眼的东西」一帧一跳，只用来定固定的窗），大半的帧
     （60%）认出了人、而且人散开超过窗宽 / 窗高的 30% 才跟 —— 走动小的一个固定的窗就框得住，不打关键帧（主轨上带关键帧的段
     导出时要先渲一遍中间片，[关键帧动画](keyframe-animation.md)，能不打就不打）。
   - 前后 0.75 秒的平均抹掉抖动，再用 RDP（1.5%）精简到转折处的点。**裁切不能做关键帧**，所以裁切固定成盖住所有窗的那一块，
     窗怎么走全靠摆放框的中心：窗左上角在 (wx, wy) 时中心 = ((K.midX − wx) / W, (K.midY − wy) / H)（K = 裁剩的那块，W × H = 窗），
     只有一个点时就是固定的那扇窗。自检照合同验：每个关键帧那一刻，窗的左右两边正好落在画布左右两边。
   - 素材里换了镜头：每个镜头各算各的，切点前一帧和切点上各一个关键帧（跳过去，不平移过去）。切点从镜头扫描拿：扫过的用缓存，
     没扫过、素材不超过 2 分钟当场扫（短素材零点几秒）。
   - 铺满换掉这一段原有的位置 / 大小关键帧（旋转、不透明度的留着）；别的放法（fit=fit、x / y / scale）遇到有位置 / 大小关键帧的段
     照旧拒绝。`follow=false` 是一个固定的窗。

32. **剪辑风格（recipes 只读、save_recipe 写，方案第 39–41 条）**：AI 自己挑，不做斜杠命令。中文叫「剪辑风格」、内置的叫「预设风格」
   （2026-09-28 改名，原来叫「剪辑套路」，方案第 53 条）；工具说明要求 AI 对用户也这么叫（英文 editing styles），代码和工具名里仍叫 recipe。
   - 内置五张是 App 资源里的 `recipe-*.md`（英文；中文稿在 [配方卡](../plans/2026-09-28-mcp-recipes.md)，**改剪辑风格先改中文稿、再同步英文**），
     所有剪辑风格共用的规矩在 `recipes-shared-rules.md`，读一套全文时接在后面。
   - 读资源**不用 `Bundle.module`**：打好的 App 里没有 SrtFlow_SrtFlow.bundle（build-app.sh 把资源摊平进 Contents/Resources），
     它会直接崩。`AIBuiltInRecipes` 从 `Bundle.main.resourceURL` 找，`swift run` 时退到可执行文件旁边的那个 bundle。
   - 用户的存在 `~/Library/Application Support/SrtFlow/Recipes/`（测试版和正式版共用，同音乐库缓存），一套一个 .md，格式和内置的一样
     （开头两行 `---` 之间写 id / title / use_for，缺了照收）；按文件里写的 id 认，不按文件名。
   - 合并（`AIRecipeCatalog`）：用户的和内置同一个 id = 用户改过的那一版，盖住内置的；内置按固定顺序在前，用户的按标题在后。
     找的时候认 id 或标题，不分大小写。
   - `save_recipe`：同名 = 改那一套，旧文件先进废纸篓再写新的，**不问**（剪辑风格是 SrtFlow 的设置，不是用户的素材；第 34 条管的是用户的文件）；
     和内置同名 = 用户自己的那一版。删一套只在设置 → AI 里（进废纸篓），AI 不删。两个工具都不碰工程：不排队、不摆窗口、不算这一轮；
     存完路由叫设置页的列表（`AIRecipeLibrary`）刷新。
   - 总说明的目录里一行：剪整片之前先 `recipes`、按合适的那套剪，用户说的永远优先；「一句话告诉用户按哪套剪」「用户想留下一种风格时提
     `save_recipe`」写在 `recipes` 自己的说明里（第一节第 6 条：总说明只放目录）。
   - **卡里提到的名字必须真的存在**：自检把每张卡（和共用规矩）里 snake_case、camelCase 的词对着工具名、所有参数名、选项词表查
     （外加结果里的 `music_credits`）。工具改了名、卡没跟着改，AI 照着卡调就会报错 —— 这条当场红。
   - **卡里的字号写明画幅、9:16 的上限放得下**（2026-09-29，[风格卡给竖屏的字号大了](../bugfixes/2026-09-29-recipe-sizes-too-big-on-vertical.md)）：
     `font_size` 和字幕的 `size` 都是「1080 高的画面上多少像素」，9:16 的画面 1920 高，同一个数字相对宽度大 1.78 倍（共用规矩第 10 条）。
     画幅里有 9:16 的卡，每个字号范围都写 `on 9:16` / `on 16:9`；9:16 的上限用生产那一套量：`set_text` 的排版在 1080×1920 上排
     14 个英文大写（Avenir Next 粗体）、8 个中文（苹方粗体）各一行、不出画面，字幕用 `SubtitleLineFit` 一行至少 9 个字号宽
     （`RecipeSizeChecks`）。工具说明里 `font_size`、字幕 `size` 也写了 9:16 的换算和数。
33. **配方卡要用的零件（第 5 块第 ① 刀补的）**：
   - `set_text`：`letter_spacing`（字距）、`animation_in_duration` / `animation_out_duration`、`animation_intensity`、`emphasis`（breathe）、
     `number`（数字滚动：一个对象，只改给了的字段；没有数字的文字从检查器那一套默认值 `NumberRoll.default` 起；`remove` 变回普通文字，
     画面上留着终值，免得整段突然空掉）。都是模型里早就有、AI 调不到的；夹紧照旧只走 `updateTextOverlay`。强调和数字形态的词表
     在小程序里抄了一份，和 App 的类型对账。
   - `set_shape filled`：长方形、正方形实心（电影遮幅、色块底、HUD 面板），线条永远是线；预览和导出都问 `drawsFilled`，
     导出的画法在 `ShapePNGRenderer`（v24，见 [工程文件](video-edit-project-file.md)）。
   - `get_timeline` 回数字、强调、字距和实心。

34. **配旁白（add_voiceover，方案第 42、43 条；声音两档：下载了 SrtFlow 自己的声音就用它，见第 35 条，没有 / 读不了的语言用 macOS 的；
   fal 以后从同一个工具再分出去）**：
   - 一次给几句旁白，一句一个文件（`<起点>/SrtFlow/配音`，文件名取这句的开头、撞名加编号），放上音频轨：落点走 add_clips 那一套
     （`AITimelineEdits.place`，撞上往上抬一轨），这一批都放进第一句新开的那条轨；没给 start 的接在上一句后面留 0.3 秒，第一句没给就在播放头
     （`AIVoiceoverPlacement`）。两步：`plan` 合成（await），`apply` 同步提交、包 `AIUndoGrouping.step`，放素材和加字幕在同一次 perform 里。
   - **挑声音**（`AIVoiceChoice`，纯值）：配方卡写的是角色（`zh_female_lively` 这类六个，小程序的词表里抄一份），运行时在这台 Mac 装的声音里挑：
     同语言同性别里高级 > 增强 > 默认，同质量里大陆普通话 / 美式英语在前；两个女声角色有两个女声就各用一个；没有这个性别就退到另一个并说一声；
     只有默认质量时结果里带「去系统设置哪儿下载」，总说明要求 AI 转告。Eloquence 那一族、老的 speech.synthesis.voice 那一族、新奇声音、
     个人声音都不用。也认系统声音的名字。活泼的音调略高（1.08）、沉稳的略低（0.94）。
   - **语速不是线性的**：`AVSpeechUtterance.rate` 0.5 = 正常，0.55 已经快 1.29 倍，0.3 只慢到 0.77 倍，中间有平台；和声音无关。按实测的表
     （`AIVoiceChoice.measuredRates`）插值反查。
   - **合成**（`AISpeechSynthesis`）：`AVSpeechSynthesizer.write` 读成 PCM（不出声）、存成 AAC 的 .m4a。**词的标记只从代理方法
     `speechSynthesizer(_:willSpeak:utterance:)` 来**，`write(_:toBufferCallback:toMarkerCallback:)` 那个回调在 macOS 26 上一次都没叫过；
     `byteSampleOffset` 是字节，除以每帧字节数（单声道 Float32 = 4）就是第几帧，和声音对得上（停顿后第一个词正好落在静音结束处）。
     缓冲、标记、didFinish 都在主线程上来，标记全在最后那个空缓冲之前，空缓冲会来两次，按 didFinish 收；缓冲先抄一份再留着；带看门狗。
   - **音量**（`AIVoiceLevel`，纯值）：两种声音写文件**只经** `AIAudioFileWriter.writeVoiceover`。先整句乘一个增益，让**说话部分**
     （20 毫秒一格，−45 dBFS 以下的停顿不算、比中位数响 12 dB 以上的尖也不算）到 −18 dBFS，最多放大 4 倍；再**限幅**：超过 −1 dBFS
     的地方只压那十几毫秒（10 毫秒一格、前后各多压一格、格间渐变，每个采样都不超过上限）。不压缩、不改音色（和音乐库「宁可响度不统一，
     也绝不压动态」一个口径）。词的时间按它返回的那份（写进去的）算。**一个尖峰不许决定整句的音量**：2026-09-28 第一版是「整句一个增益、
     按峰值封顶」，被 Kokoro 炸出来的满幅 90 倍带偏，整句压没（[案例](../bugfixes/2026-09-29-kokoro-short-pieces-explode.md)；
     更早的「啪」见 [案例](../bugfixes/2026-09-28-kokoro-voiceover-clipping.md)）。各个声音原始响度差 6 dB（−15.6 到 −21.6 dBFS），
     统一之后一批旁白换角色音量也齐。真句子写成 AAC 读回来峰值和写进去的差不到 0.05 dB，所以留 1 dB 够。以后加声音（fal 等）也只许经这一处写文件。
   - **词**（`AIVoiceWords`，纯值）：标点也会被报成一个词，并进前一个词；词尾 = 下一个词的开头再往回收掉静音；写法照识别器
     （英文词带前面的空格、标点贴在后面）。
   - **字幕**（`subtitles=true`，`AIVoiceoverSubtitles`，纯值）：词直接喂 `SubtitleSegmenter.segment` + `assemble`（断句、去标点、一行多长、
     显示时间都和生成字幕同一套），加进原文轨：和已有句子重叠的不加（报几句）；原文轨是别的语言（记的，没记按字判断、字太少不判）一句都不加；
     切不出句子不建空轨；新建的轨记成配音的语言。
35. **SrtFlow 自己的声音（本机的 Kokoro-82M，CoreML；方案第 44、48–51 条）**：
   - **模块**：`Sources/SrtFlowKokoro/` 从 speech-swift（Apache 2.0，Copyright 2025 Ivan Digital）搬来改过，App 不加第三方依赖；
     每个文件开头写着改了什么，署名和授权全文在随 App 分发的 `THIRD-PARTY-NOTICES.md`。原来 704 行的注音文件拆成了
     `KokoroPhonemizer` / `KokoroEnglish` / `KokoroBartG2P` 三个类型；法、葡、印地的词典改成从模型目录读（`Bundle.module` 在打好的 App 里会崩）。
   - **模型不打进 App**：用户在设置 → AI 点下载，或者 AI 调 `add_voiceover download_voices=true`（回任务号，任务种类 `voices`，
     要告诉用户在下）—— 同一次下载（`KokoroVoicePack`）。从我们自己的 R2 读清单，一个文件一个文件下到临时目录、核大小和 SHA-256，
     全部对上才一次换进 `~/Library/Application Support/SrtFlow/Voices/Kokoro-82M-CoreML`（测试版和正式版共用）；断了再下时核对过的跳过。
     清单是远程数据，路径不许跳出模型目录（`KokoroVoiceManifest`）。怎么传上去见 [本机配音模型的整理与上传](../build/voice-model-pipeline.md)。
     `get_status` 的 `srtflow_voices` 报下没下。冒烟用 `SRTFLOW_VOICES_DIR` 换一个地方下，不碰用户那一份。
   - **挑音色**（`AIVoiceRole` / `AIVoiceChoice`）：八个角色各对应一个音色（用户听样音定的：中文 zf_xiaoyi / zf_xiaoxiao / zm_yunxi，
     英文 af_bella / af_heart / am_fenrir，英式 bf_emma / bm_george），角色名和小程序的词表对账；54 个音色都能按名字点；没点名按文字的
     语言用默认的那个。Kokoro 能读 8 种语言（英、普通话、日、西、法、意、巴西葡萄牙、印地），别的语言用 macOS 的声音。
     没下载时用 macOS 的声音，结果里带「SrtFlow 自己的声音好得多，可以直接下载」（总说明和工具说明都写着，让 AI 知道）。
   - **读一句**（`KokoroVoiceSpeech`，在 `MediaReadQueue.voice` 上，模型闲置两分钟卸掉）：模型一次最多 128 个 token、5 秒声音。
     **放得下就整句读**（`KokoroVoicePieces.whole`，模型自己会在句号处停）；读不下才切成两半：句末 → 逗号 → 空隙，各挑离正中最近的
     一处，紧跟在「Two.」「第二。」这种标号后面的那一刀排最后；标点留在段里（语气要它）。
   - **太短的一段会炸，后面垫一句再读**（`KokoroPieceReader` + `KokoroVoicePadding`）：这个转换版读几个到三四十个 token 的输入，
     输出可能炸到满幅的几十到几万倍（「Two.」+39 dB、「好。」+43 dB，换计算单元一样，是模型的毛病）。不到 72 个 token 就在后面接
     一句中性的话（每种语言两句），读完按每个 token 的时长只留这一段自己的，切口不越过垫的那句开口处（`SpokenPiece.speechLimit`）；
     这一段自己的峰值超过满幅 2 倍（或非数字）就换另一句再读，都炸用峰值最小的那次（限幅兜底）。**所以不许再「一句一句切开读」**
     （[案例](../bugfixes/2026-09-29-kokoro-short-pieces-explode.md)）。
   - **按字 / 词切 token**（`KokoroUnits`，模块里我们自己写的）：中文一个字一个单位（整段一起转拼音，比逐字多读对一些多音字），
     数字换成读法（原来的中文注音遇到数字直接跳过：10,000 → 一万、50% → 百分之五十），夹在中文里的英文词按英语读；拼音文字一个词
     一个单位；日语整段一个单位。**模型给每个 token 一个时长，一格正好 600 个采样（25 毫秒，2026-09-28 实测：加起来正好是声音的长度）**，
     按单位加起来就是每个字、每个词在第几秒开口 —— 字幕和 macOS 配音走同一条路（`AIVoiceWords` → `SubtitleSegmenter`）。
   - **拼起来**（`KokoroVoiceAssembly`）：每一段从第一个字开口前 0.05 秒起，到最后一个字说完之后**第一段 40 毫秒的安静**处切
     （最多往后找 0.2 秒），段间按标点停。为什么在安静处切：Kokoro 读完之后常会冒一截杂音（2026-09-28 用户听出来「学完这门课」
     后面的卡顿声，在安静 140 毫秒之后才冒出来）；声音和时长之间大多差一格，偶尔差两三格，硬按时长切会切掉最后那个音的尾巴。
     每个词带自己的结束格（`Marker.endFrame`）：词尾不越过它，不然下一段开头的一点底噪会把句末的词拉到下一句。
   - 已知不足：第一个字偶尔比时长晚 0.1–0.2 秒出声（字幕略早一点）；多音字只能读对一部分（「银行」「音乐」还是错的）；中文数字按
     基数读（2026 读「二千零二十六」，不是年份的读法）。
36. **字幕长什么样（`edit_subtitles` / `burn_subtitles` 的 `style`，方案第 38、54 条；第 5 块第 ④ 刀）**：
    2026-09-29 补的三样（[案例](../bugfixes/2026-09-29-subtitle-merge-loses-word-times.md)）：`edit_subtitles` 的 `merge`
    走界面「合并」那份合同（`SubtitleTrackEditing.mergeCues`，逐词时间拼起来），别让 AI 拿「改字 + 删句」拼；`get_subtitles`
    每行报 `timed_words`；`style.max_width`（一行最宽占画面宽的几成）按这个工程的画幅换成左右边距（`AISubtitleStyleChange.horizontalMargin`，
    画布宽同 `assDocument` 的 PlayResX），只对工程字幕，`burn_subtitles` 不收。
   - 参数只有一份 schema（`MCPSubtitleExportTools.subtitleStyle`，两个工具共用）：位置（bottom / middle / top，九宫格居中的那一列，
     词表 `MCPVocabulary.subtitlePositions` 和 App 对账）、离边多远（画面高的比例）、字号（1080 高的画面上的像素）、字体、粗细、
     颜色、描边或底条（二选一）、阴影、逐词高亮的颜色和放大倍数、reset。读法和落法只有 `AISubtitleStyleChange`（纯值）一处：先全验过，
     哪一项不对一样都不改。
   - **阴影**（2026-09-29 验收实剪：纪录片的卡写着「白字加浅阴影」，AI 却没有这个参数，只好加粗描边）：`shadow` 给颜色
     （`#RRGGBBAA`）或 none，写成 true / false 也认（`set_text` 的 shadow 是开关，AI 会顺手这么写；true 是烧录页「白字阴影」那套的
     颜色）。偏移沿用那套的 3。阴影只跟描边一起画（预览、烧录都是，底条模式没有阴影）：底条模式里给阴影就回到描边，和底条一起给报错。
   - `own_style` 只说「字长什么样」是不是这个工程自己的；逐词高亮本来就属于工程，只改高亮时它还是 false（工具说明写着）。
   - **edit_subtitles 只改工程自己的样式**（`projectSubtitleStyle`，用户拍板），从此刻用的那套（`subtitleStyle(appWide:)`）改起，
     烧录页记住的那套不动。给了位置 / 离边距离就收掉拖框的布局（它锚定在底部中心，会盖住位置）；只给字号就把布局的字号倍率归一
     （倍率会乘在字号上）。高亮落到 `subtitleHighlight`。结果和 `get_subtitles` 都回「现在长什么样」（`describe`）和几句知道词的时间
     （`lines_with_word_times`：高亮只亮这些）。说明里写着**先设样式、再生成字幕 / 配音字幕**：一行放多少按设的字号和放大倍数切。
   - 给了字体要等字体表（`FontCatalogStore.loadedFonts`，最多 5 秒）：只认**烧录能用**的字体（libass 读得到文件的；苹方这种系统私有
     的预览看着对、烧出来会换成别的字，所以不认）。所以 edit_subtitles 先 await 读好 style，再把同步的提交包进 `AIUndoGrouping.step`
     （同 edit_clip，check-mcp.sh 的撤销分组扫描钉着）。
   - **burn_subtitles 的 style 只用于这一批**：落到这一批自带的一份上（`BurnInRequest.style`，烧录页记住的那套不动；页面上给这一条
     换字幕文件时它留着）；字幕文件里没有词的时间，给高亮直接报错。
   - 配方卡里带货、vlog 用高亮（带货放大 1.1、vlog 不放大），纪录片、电影开头、科幻不用；9:16 时 `margin 0.22` 放在平台按钮之上。

37. **扫画面里的字（look 的 text_scan=true）与按字取景（edit_clip 的 focus=text，方案第 55 条）**：
   - 一个视频文件（或一段用到的那一截，`AILookTarget` 和分镜头共用）每隔约 2 秒认一帧字（accurate、1280 像素、带框），最多 24 帧
     （长的就摊开），`AITextRegions`（纯值）叠起来统计，只回文字不拼图（M1 上 24 帧约 12 秒）：
     - **字幕带**：只认**画面最下面、正中**的一行（中心离正中不超过 12%、在 78% 以下、够宽不太高、不是被画面底边切掉的薄片：底边贴着 0.99 以下的边、高不到 0.04），25% 以上的帧有、字在变（不同的字 /
       有字的帧 ≥ 0.4）。报那一条的框、从哪到哪、裁掉它要 `crop bottom` 多少。**不认顶上**：2026-09-28 拿课程录屏实测，居中的幻灯片
       标题会被当成顶上的字幕，烧在顶上的字幕又少见。
       **框只量字幕那几行**（`subtitleLines`，2026-09-29，[字幕带把幻灯片标签也框进去](../bugfixes/2026-09-29-text-scan-band-swallows-slide-labels.md)）：
       烧进去的字幕底边在同一条线上、字一直在换；幻灯片居中的字随页换位置、一页停几帧就是同一句。按底边分堆（相差 0.02 以内），
       **够多的几堆里最下面的一堆**是字幕（够多 = 至少 3 句不同的话、也至少是最多那堆的三分之一；选定后按它底边的中位数再收一遍；[案例](../bugfixes/2026-09-29-text-scan-cutoff-text-and-sparse-subtitles.md)：字幕稀疏、幻灯片字多时「不同的字最多」会选成幻灯片，滚出画面只露一道的 PDF 行也会偏袒着混进来），再带上同一帧里紧贴在它上面、一样大的字（两行的字幕）——**这一行也要像字幕一样每句都换**
       （至少两帧、两句不同才认；幻灯片自己的标题恰好贴在字幕上面的一帧不是第二行，
       [案例](../bugfixes/2026-09-29-text-scan-crop-hint-stretched-by-slide-title.md)）。以前按所有居中的字取，课程录屏的框从 0.77 起、叫人裁 0.24，
       会切掉幻灯片自己的标签；现在六节课都在 0.88–0.90，裁 0.11–0.13。
       **提示写明裁的是整条带**：条里别的字（幻灯片自己贴底边的小字、PDF 页最后一行）一起没了，裁完要抽几帧看。**已知不足**：字幕压在幻灯片
       自己的字上（L16 的「三步走」页，两行说明文字在 0.83–0.95、字幕在 0.90–0.96）时，裁掉字幕必然连它一起裁，改数字没用；要盖住旧字幕又不裁，
       得等遮盖（模糊 / 马赛克块，方案第 56 条，暂缓）。**框的左右不可靠，上下才可靠**：Vision 会把字幕和同一条线上的幻灯片字并成一个宽框（L18 的 x 0.09–0.92、L28 的 0.26–0.94），报出来的 x 范围因此比真字幕宽，还随抽到的帧变（L27 生产抽样 0.12–0.85、真字幕约 0.23–0.77）；要盖住旧字幕就用整条带的宽度、只取上下。
     - **固定的字**：同样的字（只看字母数字、至少 3 个）30% 以上的帧有。按出现的地方分堆，最大那堆占八成就是固定在那儿（报框），
       不然报「会动」和去过的几处 —— 同一批课程素材里的「Sky Studio」台标就在几个角之间跳。同一处挨着的词并成一块（上下叠的按读的顺序）。
       先拿掉固定的字再找字幕带：底部正中一行不变的标题不许把字幕带撑大。**已知不足**：OCR 认小字、淡字不稳（同一个台标 24 帧里只认出
       3–17 帧），门槛因此放在三成；不是字的台标认不出来；结果里写着「看几帧确认」。
     - **满屏的字**：除去上面两样，一帧三块以上或占画面 2% 以上（和按字对准同一个 `AISubjectFocus.isTextHeavy`），40% 以上的帧这样，
       报它们通常占的那一块，提示竖屏用 `focus=text`。
   - **按字取景**：铺满时 `AIPictureProbe` 连字在哪也认一下（fast，一帧几十毫秒）；自动模式（focus=subject）里没有人脸、没有人、字多
     就对准字合起来的中间；`focus=text` 只看字、不跟拍。字合起来比窗宽时结果里报宽出去多少（`text_cut`）并建议 fit=fit。
   - 每帧的描述里的字带框（第 12 条），AI 挪字幕、按字取景、找水印都用得上。

38. **盖一块：`set_shape kind=blur|mosaic` 与 `look text_scan` 给的 `cover`（方案第 56 条，2026-09-29）**：模糊 / 马赛克是形状的一种（不新开工具、不开一个长得像的工具），
    合同和取舍在 [盖一块](cover-blur-mosaic.md)：
   - `set_shape` 加两个种类和 `strength`（2…80，1080 高画面上的像素；模糊的半径 / 马赛克每格的边长），不画东西所以没有颜色 / 线宽 / 实心 / 旋转，写回给 AI 的带 `strength` 不带 `color`；
     工具说明只加了约 330 字（总长约 66.8k / 72k）。走 `AIUndoGrouping.step` 的老路（`set_shape` 早就包着），一步撤销。
   - `look text_scan` 看的是时间线上的一段时，结果里的字幕带和固定的字各带一个 `cover`（`AICoverBox`）：源画面上的框按片段**此刻**的裁切 / 翻转 / 摆放 / 旋转换成画布上的框，
     写成 `set_shape` 直接能抄的 `x`、`y`（中心）、`width`、`height`（画布的比例）、`start`、`duration`（时间线秒）；字幕带盖整条画面宽（报出来的左右不可靠）；水印四周留一圈，
     会跳角的每处一块；顶层再有一句 `cover_hint`。看的是文件（没有片段）时没有 `cover`（没有画布可换）。
   - **盖完靠 `look`（时间线）核对**：`AIFrameComposer` 合成时把盖一块盖上（`CoverCompositing`，和预览同一份 `CoverFilters`），AI 看得到自己盖没盖住。
   - 已知不足：位置不跟着片段走（片段挪 / 缩放之后要重盖）；只按此刻的摆放换算、不看关键帧动画。
39. **生成素材（`generate_media`，fal.ai，方案第 6 块、第 57 条）**：合同全在 [fal.ai 生成](fal-generation.md)，这里只记它怎么接进 MCP 这一层。
    风格卡里提它**只写条件句**（2026-09-29 用户拍板：「如果你的工具里有 generate_media……」）—— 工具只在填了 Key 时在清单里，卡却一直读得到；
    共用规矩第 11 条和每张卡的「Generated media」一节说了有它时能补什么、不能替什么（`RecipeChecks` 钉着：提到就得在条件句下、
    词表和结果字段名都得对得上）：
   - **只在用户配了 fal 的 Key 时才出现在清单里**（方案第 36 条）：`MCPToolName.provider`；App 在 Key 添加 / 删除时和每次启动时写一个只有提供方名字的
     `mcp-providers.json`（和 socket 同目录），小程序每回一次清单 / 握手都重读它；握过手的老一代客户端收 `notifications/tools/list_changed`，
     新一代靠清单一分钟的缓存时间。没配时总说明里也不提它。全清单的说明总长度量的是每个提供方都配好时的样子。
   - **生成是任务**：立刻回任务号（带估价、今天已花、每日上限），`get_job` 等；不改工程、不进撤销分组，放上时间线是 `add_clips`。
   - **花钱超了额度、或价格不明，先在提示条上问用户**（`AISession.ask`：允许 / 先不要，不弹模态框、不管这一轮什么状态都摆出来），任务带 `waiting_for_user`；
     用户按停止 / AI `cancel_job` 都把问题收回。同步的工具（配旁白）不能停下来问，额度不够就退档。
   - 图生视频的首帧图、克隆的素材会发给 fal.ai：点名文件夹以外的先问一次（同读别处的文件，`confirmReading` 的动词是「send to fal.ai」）。
40. **配旁白的 fal 那一档（`add_voiceover`，方案第 42、52 条）**：声音三档 fal > SrtFlow 自己的（Kokoro，第 35 条）> macOS（第 34 条）。fal 那一档只在
    有 Key、没超每日上限、Key 读得出来时用，不行就退档并在 `voice.note` 里说为什么；点名 Kokoro 的音色或这台 Mac 的声音仍照点名。fal 的声音也**只经
    `AIAudioFileWriter.writeVoiceover` 落盘**（第 34 条那条扫描加了它）。`clone_from` / `clone_start` / `clone_seconds`：用素材里一段人声克隆，只有 fal 能做、
    用不了就报错不退档。词时间读不出来就没有（结果里说，改用 `generate_subtitles`）。

41. **婚礼工程那一轮之后补的五条小规矩（2026-09-29，[案例](../bugfixes/2026-09-29-mcp-tool-followups-from-wedding-session.md)）**：
    ① 说明里写的记号客户端会照字面传：`set_text` 的 `text` 把字面的 `\n` 也当换行（`AITextChange.unescapingNewlines`）。
    ② 切工程只取消绑工程的转写：`TranscriptionTask.cancelIfBoundToProject()`（生成字幕绑、AI 的 `transcribe` 只转文件不绑），
    `new_project` / `open_project` 不许顺手把文件级的 transcript 取消了；用户按「停止」照旧全取消。③ `look` 建完合成先
    `isValid`，无效就报错说「这是 SrtFlow 的 bug，不是素材黑」，不许把黑底交给 Vision 描述。④ 整批的工具（`delete_items`）
    先把 id 全认一遍，认不出的一起列出来、说明一个都没做（`AITimelineEdits.deletion(of:in:)`）。⑤ `get_timeline` 顶层带
    `project`（工程文件名 / `unsaved`）：几个 AI 会话连着同一个 App 时，谁刚换了工程一眼能看出来。
42. **为机器设计接口的三条（2026-09-29 用户拍板：现在主要是 AI 在剪，不照搬给真人的惯例；[案例](../bugfixes/2026-09-29-keyframes-outside-clip-after-ai-edits.md)）**：
    ① **没有隐藏状态** —— 报出来的就是存下来的，AI 看不见的东西不许影响下一步（关键帧永远在片段范围里、分割后两半各留自己的）；
    ② **坐标只用它用的那一套** —— 时间线秒，或片段的比例（`set_keyframes relative=true`），不让它自己换算素材时间；
    ③ **每个改动的结果把连带发生的事说清楚**，意图用参数说而不是靠拖拽的惯例（`edit_clip keyframes` = keep_frames / stretch / clear，
    结果里 `keyframes_note`；`split_clip` 的结果给两半各自的关键帧）。以后每个工具都照这三条审。

43. **合成音效（`add_clips` 的 `sound_effect` 条目 + `hit_at`，2026-09-30；合同全在 [合成音效](sound-effect-synth.md)）**：不另开工具
    （第一节第 5 条：先看加参数行不行），条目和 `file` / `library_id` 并列，三个只给一个；预设名走词表 `MCPVocabulary.soundEffectPresets`
    （和 App 的 `SoundEffectPreset` 对账）；`hit_at` 是时间线秒，工具按声音自己的落点反算开头（负了从声音中间放），没给 `hit_at` 也没给
    `start` 就放在播放头，结果里报出 `hit_at`；文件放 `<起点>/SrtFlow/音效`、同参数同文件不重写（不算覆盖、不问）；写文件只经
    `AIAudioFileWriter`、渲染在 `MediaReadQueue.analysis` 上；段默认 −8 dB。**AI 的顺序（用户定）**：先 `find_audio` 找录音（音效库做完后）、
    没有合适的用 `sound_effect`、真实声音都没有才 `generate_media` —— `find_audio` 和 `generate_media` 的说明、风格卡都这么写；总说明目录
    Sound 那一行带着它。清单预算：加它之前 71,612 / 72,000，把二十几个工具的说明各收了一截才放进去（71,813；音效库的 kind 加上后又收了
    find_audio 的说明）。音效库那一半在第 23 条。
44. **放大片段（`upscale_clip`，fal.ai，2026-10-02）**：合同全在 [视频 upscale](video-upscale.md) 第五节和 [fal.ai 生成](fal-generation.md)
    第十二 / 十三节，这里只记它怎么接进 MCP 这一层。
   - **和 `generate_media` 一样只在配了 fal 的 Key 时列出来**（`MCPToolName.provider`）；总说明的 fal 那一行带着它（Claude Code 开场只看目录）。
     清单的说明总长度上限为它从 72,000 抬到 **80,000 字符**（2026-10-02 用户定；`ProtocolChecks`）。
   - **参数和面板同一份数**：`clip_id`，可选 `tier`（六个档位，词表 `MCPVocabulary.upscaleTiers` 和 `FalUpscaleTiers.all` 对账）、`target`（`1080p` /
     `1440p` / `2160p`，按短边叫，4K 写成 2160p）、`range`（`clip` / `longest` / `file`）；默认和面板一样（目标按画布、范围别处用得更长就 longest）；
     范围、估价、档位可不可用都由 `UpscalePanelModel` 算（`AIUpscaleNames` 认词）。源已经不比目标小就拒绝；音频 / 图片 / 定格段拒绝；
     同一个原片正在做就拒绝。`get_timeline` 给每个画面段 `source_size`，AI 据此判断该不该放大。
   - **是任务**：立刻回任务号（带估价、送去几秒、输出尺寸、会换哪些段、今天已花 / 上限、`next_step`），`get_job` 带阶段（第 7 条：
     `phase` / `queue_position` / `transfer_percent` / `phase_seconds` / `typical_seconds`）；任务种类 `upscale`；`cancel_job` / 停止把它从
     `UpscaleActivity` 拿掉（替 fal 也取消、不留文件）。
   - **花钱按每日上限把关**，和 `generate_media` **同一处**（`FalJobGate.reserve`：额度内直接记账；超了 / 价格不明先在提示条上问、任务带
     `waiting_for_user`；用户不要就 `declined`、没花钱）；钥匙串授权框的提醒也共用（`FalJobGate.showKeyPromptHint`）。面板起的 upscale
     不经它（面板本身就是确认）。`checks/fal-wiring.sh` 第 4、5 条钉着「把关和提问只在 FalJobGate 一处」。
   - **做完直接换源**（2026-10-02 用户定：AI 起的不弹对比窗口）：`UpscaleActivity.add(job, opensCompare: false)`，`onFinished` 里一次
     `applyUpscale`（工程里用这个原片且范围被盖住的段一起换），**自己包一层 `AIUndoGrouping.step`**（异步落账，第 1 条；
     `scripts/check-mcp.sh` 的扫描钉着）、算这一轮的一处改动、选中换了的段并把播放头放过去（后台模式不动）、没存过的工程存一下；
     结局带 `replaced_ids` / `file` / 宽高 / `cost_usd`（查到实收前是估价，`cost_is_estimate`）。原片留在旁边：用户随时右键
     「Compare with Original…」/「Revert to Original Clip」，⌘Z 一步撤回。工程中途换了（`documentGeneration` 变了）就不换、结果里说明。
   - 失败 / 取消 / 用户没点头各自一句话（`settle`），都不扣钱（fal 只对做出来的收）；用户在状态行上按 Stop 也算取消。

## 五、这一轮、停止、撤销这一轮

- **一轮按时间划分**：服务器看不到对话。AI 开始改工程时开一轮、存一份时间线快照；30 秒没有新调用算结束，
  横幅换成「改了 N 处 · 撤销这一轮」。
- **撤销这一轮** = 把时间线**原样**换回快照（一步，可以再 ⌘Z 回来）。AI 中途换了工程，快照跟着换成新工程开始时的样子。
  只许走 `VideoEditProject.restoreTimeline`（和 ⌘Z 同一条收尾 `adopt`），**不许走 `perform`**：那是一次编辑的收尾，磁吸会把快照里
  V1 的缝又合上、联动再按合拢挪一遍，结果音频字幕回了原位、V1 没回（[案例](../bugfixes/2026-10-02-undo-round-repacks-v1.md)，
  守卫 `checks/timeline-drag-wiring/linkage.sh` 第 12e 节）。
- **停止**：取消在跑的导出 / 生成字幕 / 翻译；之后 AI 的调用一律回「用户按了停止」，直到它安静 10 秒 ——
  AI 收到拒绝会停下来问用户，用户再说话时新的一轮照常开。排在队里、还没轮到的改动也不做了。
- 横幅（`AIActivityBanner`）只订阅 `AISession`，不读工程，放在**预览栏的顶上**（剪辑页 `previewPane` 的第一行，
  只在 AI 活动时出现）。第一版挂在主窗口 detail 的 `safeAreaInset` 上：剪辑页的分栏是 AppKit 的，不认 SwiftUI 让出来
  的那条边，横幅压在了素材库那一排页签上；用户看了截图说放到预览顶上的空白处（2026-09-27）。

## 六、「连接 AI」（设置 ⌘,）

| 客户端 | 配置 | 怎么改 | 为什么 |
| --- | --- | --- | --- |
| Claude 桌面版 | `~/Library/Application Support/Claude/claude_desktop_config.json` | 直接改（第一次改前备份成 `.srtflow-backup`） | 官方就是让用户改这个文件 |
| Claude Code | `~/.claude.json` | 走它自己的命令行 `claude mcp add --scope user`；找不到命令行就「复制一段话」 | 正在跑的 Claude Code 会整份重写这个文件，直接改会被冲掉 |
| Codex | `~/.codex/config.toml` | 直接改 `[mcp_servers.srtflow]`（先备份） | 桌面版和命令行共用一份，很少被程序重写 |

只动 `srtflow` 这一项，别的原样留着；文件格式不对就报错、一个字节都不写（`AIClientConfigFiles`，自检钉着）。

**连上的同时放行 SrtFlow 的工具**（方案第 35 条，2026-09-28）：客户端自己第一次用每个工具都会问一次「允许吗」，
40 多个工具就是 40 多次。这一层全放行，SrtFlow 那一层只拦删文件（第四节第 6 条）。

| 客户端 | 放行写在哪 | 断开时 |
| --- | --- | --- |
| Claude Code | `~/.claude/settings.json` 的 `permissions.allow` 加 `mcp__srtflow`（官方写法：匹配这个服务器的每一个工具；第一次改前备份） | 只去掉这一条 |
| Codex | `[mcp_servers.srtflow]` 里 `default_tools_approval_mode = "approve"`（Codex 0.144 起认这个键） | 跟着整张表去掉 |
| Claude 桌面版 | 没有能写的文件：「总是允许」存在它自己那里。连上之后的提示里告诉用户在它的连接器设置里一次设好（按只读 / 写入两类） | —— |

以前连的、还没放行的显示「已连接 · 每次都会问」，再点一次「连接」补上。「复制一段话」里同样写了这一步。

设置页**一行只放一个按钮**（2026-09-28 用户：没连上的时候不该显示断开，精简下）：连上了是「断开」；没连上、连着另一份、每次都会问都是「连接」；「连接」在这台机器上用不了（Claude Code 找不到命令行）时换成「复制一段话」（`AIClientSetup.canConnect`）。
配置里写的是**这一份 App 包里**的小程序路径，状态里「连着另一份」= App 挪过位置或装过测试版，点一下重连。

## 七、守卫

`scripts/check-mcp.sh`（CI 第 4 组）：真起小程序，两代客户端各喂一遍（握手、清单、discover、版本错误、
工具调用转发、客户端名字、整数 id、App 没开）；AI 改时间线的规则；客户端配置的增删；文字 / 颜色参数、
字放不放得下；字幕批量改；词表对账；打包脚本把小程序拷进 Helpers 并且先签它再签外层；**每个改动工具各是
一步撤销**（扫描路由的包装 + 用真的 UndoManager 验分组、验不会再抛异常）；窗口只在一轮开始时摆到前面（扫描）；
**画面的放法**：铺满时窗的四个角正好落在画布四个角上（6 种素材比例 × 4 种画布 × 49 个焦点，按合同自己换算，
不借被测代码）、裁切每边不超过 0.45、焦点落在画布正中、只改裁切不拉变形、参数冲突挡掉；去黑边的几种画面
（遮幅、柱边、黑场、星空、遮幅里的字幕、几帧取最小），以及真画一张图读回来第一行是画面最上面；对准主体的挑法
（人脸优先、放得下对准中间、放不下对准最大的、中位数、走动大了要说），以及真画一张图（黑底左上角一块亮色）让 Vision
认、框必须落在左上；look 的拼图排法和尺寸、JPEG、每帧的文字描述、图跟在文字后面，以及几百 KB 的图原样穿过
小程序 ↔ App 的通道（假 App 回一张大图）；listen 用生产的 `ChunkBuilder` 攒一份波形（响 1 秒 → 静 1 秒 → 轻 1 秒），
验电平只算有声部分、峰值、静音段两头不被隔壁拖短、曲线、变速和音量换到时间线上；音乐库的署名句（CC0 不署、同一句
只出一次、按艺人和标题排）和 get_timeline 里音乐库的段写 `library_id`；第 3 块：转写结果按句读、翻页（`next_from` 接得上）、
鼓点（合成的鼓点声和鼓组：速度、每拍离真拍点多远、不许跟到后半拍的踩镲上、长音不许造出拍子）、cut_speech 的切口（落在空隙中点、
按词的中点判归属、合并与对齐帧、真落到带链接声音的时间线上）、cut_to_beat 的排法和落到时间线上；压缩 / 烧录的参数怎么落到设置上（不给就是页面记住的、
只改那四项、两种编码器的画质档）、输出起名（硬盘上撞、同一批里撞都加编号）、GBK 字幕转格式，以及扫描：队列跑一条先用
它自带的设置、重算输出位置跳过 AI 的条目、有用户没开始的条目就不排、不改页面上的设置；什么时候问（扫描：会回
`needs_confirmation` 的只有删文件和读别处的文件两处、点过头就记住那个文件夹、导出 / 新建 / 另存撞名走
`ExportFileName.unoccupied`）、记住哪里（`ReadGrantChecks`：文件所在的文件夹，太大的只记文件，子文件夹算、名字相像的兄弟
不算）、连接时写的放行配置（Claude Code 那条规则的增删不碰别的设置、坏文件不写；Codex 那一行只认 srtflow 那张表里的）、
工具清单的总长度（7.2 万字符以内）；第 4 块：镜头切点的规则（硬切、摇镜头、动作里的硬切、几帧的转场、淡出淡入、闪光、
太近的两刀、片尾片头的黑）、镜头按区间裁和翻页，跟拍（要不要跟、只跟人、人只在少数帧出现不跟、平滑与精简、换镜头处一帧之内
跳过去、一个点就是固定的那扇窗、每个关键帧那一刻窗的两边正好落在画布两边、关键帧写在源秒上、铺满换掉位置 / 大小关键帧而
旋转和不透明度留着）；第 5 块：配方卡的格式和写回、名字 → id、内置和用户的合并与查找、存一套（同名改那一套、旧的挪走、内置的名字 =
用户的版本）、删一套、recipes / save_recipe 的结果、五张内置卡都在而且每张说了什么时候用、**卡里提到的工具名 / 参数名 / 选项值都存在**、
**卡里的字号写明画幅、9:16 的上限真排得下**，
总说明里有「先挑剪辑风格」；set_text 的字距、动画时长和强度、强调、数字滚动（默认值起、只改给了的、remove 留终值），set_shape 的实心
（线条永远是线、回给 AI 的是 filled）；add_voiceover 的挑声音（角色、质量、地区、两个女声、退性别要说、默认质量要提示、几族不用、按名字）、
语速表（1 倍 = 0.5、越快越大、夹住）、标记 → 词（标点并进前一个、词尾收静音、每个词从标记开始）、每一句放在哪、配音的字幕（去标点、从开口算、
不覆盖已有的、字太少不判语言、别的语言一句不加、没句子不建空轨）、配音的音量（峰值超过满幅的一句真写成 .m4a 读回来不削波、峰值正好压在
−1 dBFS、调响一句轻的也不冲过上限、说话部分同一个响度、停顿不算、静音原样、底噪最多放大 4 倍；两种声音都只经 `writeVoiceover` 写文件是扫描）；
SrtFlow 自己的声音：装了就用、角色对应的音色、没下载时点名要报错并叫
AI 下载、读不了的语言用 Mac 的，切段（句末、逗号、正中间）、拼接（在第一段安静处切掉尾巴杂音、词的开口和结束）、R2 清单的校验（路径不许
跳出模型目录、SHA-256）、按字 / 词切 token（中文一个字一个单位、数字换读法、夹着的英文词、英文按词）；字幕的 style（参数全验过、
只改工程自己的样式、给了位置收掉拖框的布局、只给字号把倍率归一、高亮的开关和倍数、烧录一批时描边 / 底条互换、阴影（颜色 / 开关、
底条模式里给阴影回到描边、和底条一起给报错）、烧录用不了的字体
报错、位置词表对账）；扫画面里的字（字幕带只认下面正中、会变的字；固定的字先拿掉、会动的报几处、挨着的词并成一块；满屏的字；
没人、字多时按字对准，focus=text 只看字、字比窗宽报多少）。真合成、真下载要系统声音、
网络和模型，靠人工回归清单。合成时间线画面、下载音乐、真编码要真 App，靠下面的人工回归清单。

**给 AI 的文字按客户端怎么读来守**（`checks/MCP/CatalogTextChecks.swift`，跟着 `scripts/check-mcp.sh` 跑）：总说明（没配 / 配了提供方两种样子）
和每个工具的说明都在 Claude Code 的 2,048 字以内（按 UTF-16 数，同它的 JavaScript 长度）、总说明前 512 字点到
open_folder / get_timeline / look / export_video、目录里有清单的每个工具名（整词）、总说明和整份清单没有汉字。
2026-09-30 反向验证：把工具说明换回改之前的版本，红 36 项（总说明 4,433 / 4,775 字超长、前 512 字缺三个、目录缺 13 个工具名、
edit_clip 2,074 字超长、清单里有汉字）。

`checks/timeline-drag-wiring.sh` 的「落点单一」一节把 AI 放素材单独数：拖文件进来那套仍是恰好两处
（画框、落地），`AITimelineEdits.swift` 里恰好一处 —— 一处都没有就是 AI 另算了一份落点
（2026-09-27 反向验证：拿掉那一处调用，守卫当场红）。

**fal.ai 生成（第 6 块）**：`scripts/check-fal.sh`（`check-all` 第 2 组，不碰网络）、`scripts/check-mcp.sh` 里的 `ProviderChecks` /
`FalVoiceChecks`（清单按 Key 列不列、老一代收 list_changed 新一代不收、小文件读写、挑音色、词时间、WAV）、`checks/fal-wiring.sh`（先问后花、不弹模态框、
Key 只经一处读、清单跟着 Key 走）、`scripts/check-fal-keychain.sh`（本机手动）、`scripts/fal-models/refresh.sh`（联网手动）。细节见
[fal.ai 生成](fal-generation.md) 第十一节。

合成音效（第 43 条，`SoundEffectChecks`）：16 个预设渲得出、峰值 −1 dBFS / 响度 −9 LUFS 封顶、落点在声音里且实测峰值离它不远、末尾淡完、同参数逐采样一致、换 variation 就不同、同参数同文件名、频谱走向（whoosh 先升后降、riser / suction 升、downlifter 降）、参数范围、`sound_effect` 条目怎么读、落点怎么算开头、词表对账、总说明提到它；扫描：合成器和工具不碰 `AVAudioFile`、渲染在 `MediaReadQueue.analysis` 上。
## 八、人工回归清单（发版前在真机上走一遍）

- [ ] 设置里连接 Claude 桌面版 → 重启 Claude → 工具列表里有 srtflow 的全部工具（个数 = `MCPToolName` 的条数）。
- [ ] 装上这一版、新开一个 Claude Code 会话（`claude -p` 就行，可以 `--strict-mcp-config --mcp-config` 只挂 srtflow），看它的 MCP 日志
      `~/Library/Caches/claude-cli-nodejs/<会话所在目录，/ 换成 ->/mcp-logs-srtflow/` 里最新的 .jsonl：服务器版本是这一版、**没有**
      「truncated」（截了会写「Server instructions truncated from … to 2048 chars」「Tool "…" description truncated from …」）。
      再让模型照抄总说明的最后两行、用 ToolSearch 加载 edit_clip 照抄说明结尾，都不是「… [truncated]」。配了 fal 的机器上多看一眼 generate_media。
      Claude Code 改了这个上限（它的 MCP 客户端里写死的 2048）就要跟着改 `CatalogTextChecks` 的 `claudeCodeTextLimit`。
- [ ] SrtFlow 没开时让 AI 调一个工具：SrtFlow 在后台启动，对话窗口不被挤下去，调用成功。
- [ ] 让 AI 打开一个文件夹、放几段素材：剪辑页被摆到最前面但键盘还在对话框里；每一步时间线滚过去、选中、
      预览跳到那一刻；顶上横幅「Claude 正在剪辑这个工程」。
- [ ] 跟 AI 说「后台做就行」：它调 `set_view background`；之后 SrtFlow 不跳到前面、时间线上的选中和播放头不跟着动，
      改动照样在、⌘Z 照样一步一步退；说「让我看着」后回到看得见。
- [ ] AI 连续改的时候切到别的 App、把它的窗口盖在 SrtFlow 上面：这一轮剩下的步骤里 SrtFlow 不再跳到前面
      （横幅、时间线照样在后面跟着动）；停 30 秒以上再让 AI 改，新的一轮开始时它摆到前面一次。
- [ ] ⌘Z 一步退掉 AI 的一个调用；停 30 秒后横幅变成「改了 N 处」，「撤销这一轮」整轮退回，再 ⌘Z 又回来。
- [ ] 磁吸开着、打开一个 V1 有缝的工程，让 AI 改几处之后按「撤销这一轮」：V1 的缝和压在上面的旁白、字幕一起回到原位（不是只有音频字幕回去）。
- [ ] SrtFlow 在后台时让 AI 放素材并**带一个字幕文件**、再改几步、再让 AI 生成字幕或翻译、再改几步：`undo` 一步只退掉
      最后那一处（以前从挂字幕 / 字幕回写那一刻起全并成一步）。
- [ ] 按「停止」：在跑的导出被取消，AI 下一个调用收到「用户按了停止」并停下来问你。
- [ ] 导出到已有同名文件：自动加编号（「标题 2.mp4」），不问、没动原来那个。
- [ ] 自己在未命名的工程里剪几刀、不存，再让 AI 新建工程：不问，原来那个被存进 `SrtFlow/工程`（AI 说得出存在哪），
      SrtFlow 里**没有**弹任何对话框。
- [ ] 把一个工程改到预览合成无效（本地临时把 `CompositionSlices` 的去重改回按秒、开用户的最小复现工程）再让 AI `look`：
      收到「preview composition is invalid … a SrtFlow bug」的报错，不是一张黑图配「夜空」的描述。
- [ ] 让 AI `transcribe` 一个文件，任务在跑时让它 `new_project`：`get_job` 照样跑到 done；让它 `generate_subtitles` 时
      `new_project`：那个任务是 cancelled（绑工程的才取消）。
- [ ] 让 AI 看 / 听 / 放点名文件夹以外的一个文件：第一次在对话里问；同意之后同一个文件夹里别的文件不再问；
      设置 → AI 里列着那个文件夹，点「移除」之后再读又会问；退出重开 SrtFlow 仍然记得。
- [ ] 设置里连接 Claude Code / Codex，新开一个会话：用 SrtFlow 的工具不再弹「允许吗」；让 AI 删一个文件时 SrtFlow
      仍在对话里问。以前连过的显示「已连接 · 每次都会问」，再点「连接」之后变成「已连接」。
- [ ] 连接 Claude 桌面版：提示里说去它的连接器设置把 srtflow 的工具设成总是允许；照做之后不再弹。
- [ ] 让 AI 分镜头看一节十几分钟的课（look shots=true）：第一次回任务号，get_job 有进度，完了再调一次按页列出镜头（带幻灯片上的字）；
      再问同一个文件当场就有。
- [ ] 让 AI 一次看二十几个镜头（look files）：图上每格标着文件名，和文字里的标签对得上。
- [ ] 横屏素材放进 9:16 工程、一个人在画面里走动的镜头 fit=fill：预览里人一直在画面里，窗跟着平移、不抖；素材中间换镜头的地方
      窗直接跳过去；导出的成片和预览一样（带关键帧的段走预渲染）。只有风景 / 动物、没有人的镜头：一个固定的窗，不打关键帧。
- [ ] 生成字幕 / 翻译：AI 拿到任务号，用 get_job 等到 done；时间线上的字幕和手动生成的一样。
- [ ] 在一个没存过的工程上让 AI 改一处：`<点名文件夹>/SrtFlow/工程` 里马上出现工程文件，窗口标题换成它的名字，
      AI 告诉用户存在哪；没点名文件夹时在「下载/SrtFlow/工程」。手动 ⌘⇧S、⌘O、导出面板第一次打开，都不再是「影片」。
- [ ] 翻译到一种没下载过的语言：SrtFlow 跳到最前面、弹出系统的下载框；提示条和 AI 都说「去点下载」；
      下完之后提示变成「点 Done」，翻出来的语言对（原文先被 AI 改写成别的语言也对）。
- [ ] Codex 连接同一套走一遍。设置页每行只有一个按钮：连上了只有「断开」，没连上只有「连接」；Claude Code 找不到
      命令行时那一行只有「复制一段话」，贴进 Claude Code 它自己装好。
- [ ] 同时开两份 SrtFlow（正式版 + 测试版）：各自的 AI 只连自己那份。
- [ ] 让 AI 用 look 看时间线上有文字、字幕、滤镜、裁切过的一刻：回来的图和预览里那一刻长得一样（文字位置、字幕、
      调色、铺满与否都对得上）；看一个素材文件：6 帧拼成一张、每格标着时刻。
- [ ] 让 AI 把一段横屏素材 `fit=fill` 放进 9:16：人脸在画面里、没被裁掉一半；带遮幅的素材 `remove_black_bars`
      之后上下的黑边没了。
- [ ] 在访达里选几个视频，跟 AI 说「用我在访达里选中的」：第一次弹「SrtFlow 想要控制访达」，点好之后 AI 拿到的正好是
      选中的那几个；什么都不选、只开着一个访达窗口时拿到的是那个文件夹。点「不允许」时 AI 说得出去系统设置哪儿开。
- [ ] 让 AI 整理点名文件夹（「把企鹅的镜头放进一个文件夹」「删掉 .tmp」）：移动 / 建文件夹直接做；删除先在对话里问，
      同意后进了废纸篓；工程里用到的素材被挪了，预览照样找得到。
- [ ] 给 AI 一份 Word / PDF 讲稿让它读：文字对；给 Pages 文件时它说请你导出 PDF 或 Word。
- [ ] 让 AI 配一首平静的钢琴曲：它用 find_audio 搜、add_clips 带 library_id 放上音频轨；没下载过的先下载（音频库页上
      那一首也变成已下载）；做完它给出署名句，和音频库「署名」页上那一句一字不差。
- [ ] 让 AI 把两段视频压成 720p：压缩页的队列里出现这两条并开始跑，页面右边的设置没被改；`SrtFlow/导出` 里是
      `…_compressed.mp4`，再压一次变成 `…_compressed 2.mp4`；AI 报的大小和访达里一致。压缩页里先放一条自己的、不点开始，
      再让 AI 压：AI 说要你先开始或移掉，你那条没被启动。
- [ ] 让 AI 把一个 .srt 烧进对应的视频：字幕的样子和烧录页预览里一样；让 AI 把一批 .srt 转成 .vtt：`SrtFlow/导出` 里
      多出同名 .vtt，原来的文件没动。
- [ ] 让 AI 转写一节课（transcribe）：第一次回任务号、等完再调一次秒回；句子的时间点下去，预览里说的正是那句。
- [ ] 让 AI 把一段口播的停顿缩短、去掉口头禅（cut_speech）：听起来不吞字、不切半个词，停顿处还留一点气口；⌘Z 一步整个回来；
      片段分离过声音时，画面和声音在同样的地方剪。
- [ ] 让 AI 把几段镜头踩在一首有节奏的配乐上（cut_to_beat）：切点和鼓点对得上；换一首很平的钢琴曲，AI 说拍子不清楚、不踩。
- [ ] 让 AI 用 listen 量一段有停顿的口播：静音段落在停顿上（前后差不过一两个字）；把配乐压到比人声低 15 dB 左右
      之后，预览里听着人声清楚。

- [ ] 让 AI 把一个文件夹剪成整条片子（「剪成 30 秒的推广」「做个电影感的开头」）：它先调 recipes、用一句话说按哪套剪；剪出来的时长、
      节奏、字、滤镜照那一套。你说了别的要求（比如不要音乐）它照你的。
- [ ] 跟 AI 说「以后都这么剪，存成我的剪辑风格，叫课程推广」：设置 → AI 的「剪辑风格」里出现这一行，「在 Finder 中显示」打开的 .md 读得懂；
      再让它改这一套：废纸篓里有旧的那份；点「删除」之后那一行没了，文件在废纸篓里。
- [ ] 电影开头的上下黑条（实心长方形）：预览和导出的成片里都是整块黑、上下一样高；检查器里「实心」开关打开时线宽那一行消失。
      用 0.16.1 打开这个工程：因为是 v24，它拒绝打开，不会把黑条悄悄变成一圈描边。
- [ ] 让 AI 加一个从 0 滚到 10,000+ 的数字：预览里老虎机滚到位；让它「变回文字」之后画面上留着「10,000+」。
- [ ] 让 AI 给几段画面配中文旁白（subtitles=true）：`SrtFlow/配音` 里一句一个 .m4a，时间线上新开一条音频轨、一句一段；预览里听到的就是
      系统的声音，字幕和声音对得上（停顿之后那一句不早出）、没有句号逗号；⌘Z 一步把旁白和字幕一起退掉。只装了默认质量的声音时，AI 转告
      「去系统设置 → 辅助功能 → 朗读内容 → 系统声音 → 管理声音下载」；下载一个高级的中文女声之后再配，结果里是那个声音。
- [ ] 已经有字幕的地方再配一句带字幕的旁白：原来的字幕不动，AI 说有几句没加；原文轨是中文时配英文旁白：字幕一句不加、AI 说明原因。
- [ ] 设置 → AI 的「SrtFlow 配音声音」点下载：进度走完（约两分半）变成「已下载」；中途点「停止」再点下载，从停下的地方接着下。
      之后让 AI 配中文旁白：用的是 SrtFlow 的声音（结果里 quality 是 SrtFlow voice），听起来自然、句尾没有卡顿声、「10,000」读成「一万」；
      字幕对得上。点「删除」之后再配：退回 Mac 的声音，AI 说可以下载 SrtFlow 的声音。
- [ ] 没下载时跟 AI 说「用好一点的声音配」：AI 调 download_voices、告诉你在下，下完接着配。
- [ ] 让 AI 按带货风格剪一段竖屏：它先 `edit_subtitles style`（大字、高亮、margin 0.22）再生成字幕；预览里说到的词变黄、稍微变大，
      导出的成片同一时刻一样；烧录页记住的样式没变；字幕表表头说「这个工程用自己的字幕样式」。
- [ ] 让 AI 用一个烧录用不了的字体（「用苹方」）：它收到报错和能用的字体表，换一个再设。
- [ ] 让 AI 对一段带中文字幕的课程录屏做 `look text_scan`：报出底部的字幕带和要裁多少；台标报成固定的字（跳角的标「会动」）；
      满屏的字提示 focus=text。然后让它把这段转成 9:16：幻灯片那段按字取景，字比窗宽时它说宽出去多少、问要不要改完整显示。
- [ ] 照 text_scan 的提示裁掉旧字幕后抽几帧（课程录屏 L16 的「三步走」页、L27 的 PDF 页）：旧字幕没了；幻灯片自己贴底边的小字
      会被一起裁掉一截 —— 提示里已经写了，AI 应该看出来并告诉用户，而不是说「干净了」。
- [ ] 让 AI 烧一批外部视频的字幕、给黄色大字：出来的是黄色大字，烧录页的样式和队列里用户自己的条目不受影响。
- [ ] 用 en_male（am_fenrir）配「One. …」「Two. …」「Three. …」这样一字开头的三句：开头没有爆音（2026-09-28 用户听到过）、**后面的话
      也不会变得几乎听不见**（2026-09-29 第一版修法之后就是这样）；同一批里再换 zh_female_warm、en_male_british 各配一句，几句听起来一样响。
      再配几句只有一两个字的（「Go!」「好。」「我们开始吧。」），听着是正常的字、没有杂音。

- [ ] fal.ai 生成、fal 的声音、克隆：整套人工回归清单在 [fal.ai 生成](fal-generation.md) 第十一节（要真 Key）。
- [ ] 让 AI 「在 12.0 秒的切点上放一个 whoosh」：时间线上块的最响处压在 12.0 秒、块开头在它前面约 0.55 秒，结果里 `hit_at` = 12.0；同参数再放一次，`SrtFlow/音效` 里不多出文件（第 43 条）。

## 九、已知不足（第一期）

- 「一轮」按 30 秒没动静划分：AI 想得久会被切成两轮。
- 「撤销这一轮」换回的是整条时间线：这一轮里用户自己动过的也会一起退回。
- 压缩 / 烧录的进度只有侧边栏上那个角标；AI 起的任务不会把主窗口切到那一页。
- 音效库还没做（App 里只有音乐）；接了 fal 的用户可以让 AI 生成音效（`generate_media` 的 `sound_effect`），没接的 AI 找不到音效。
- 转写要 macOS 26（SpeechAnalyzer）；macOS 15 上 transcribe 报「需要 macOS 26」，cut_speech 只能删停顿和按时间剪。
- 鼓点对很平、没有鼓的音乐不可靠（照实说「拍子不清楚」）；小节头是猜的（四种相位里起音最强的那个）。
- Claude 桌面版的「总是允许」只能用户自己在它的界面里设，Claude 更新之后可能被重置（官方已知问题）。
- 叠化认不出镜头切换（照一个镜头算）。描述一页 24 个镜头要十几二十秒：关键帧稀的长课（10 秒一个），每个镜头的中间帧都要
  从关键帧解起。扫描本身 M1 上 1440p 约 17 倍速。
- 跟拍只跟人（动物、车走动时是固定的窗）、只平移不缩放。
- ChatGPT 聊天框连不上（只认网上的地址），用 Codex 代替；DeepSeek / Qwen 放第二期。
- 配方卡进 App 的只有英文；中文稿在 docs 里，两份要手动保持一致（改剪辑风格先改中文稿）。
- 音乐库 79 首几乎都是氛围、古典、钢琴，带货和 vlog 要的轻快配乐很少；卡里写了找不到就不放、请用户给一首自己的。
- macOS 自带的默认质量声音比较机械（2026-09-28 本机中文只有默认的婷婷）；好的声音要用户自己在系统设置里下载。语速表是在 macOS 26 上量的，
  系统升级后可能要重量。
