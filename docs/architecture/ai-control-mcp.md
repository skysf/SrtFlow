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
3. **说明文字用英文**（模型读英文最准；AI 回用户时用用户的语言）。每条写清：做什么、不传的参数怎么办、
   什么时候会回 `needs_confirmation`。所有工具共用的规矩写在 `MCPInstructions`（客户端会放进模型的上下文）。
4. **stdout 只许写 MCP 消息**，一行一条，字符串里的换行必须转义（`JSONValue.encodedData` 就是这么写的）。
   调试输出写 stderr。

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
   磁吸收尾、预览重建都走原来那条路。不要在一个工具里连着 perform 好几次。
2. **能复用手动操作的全复用**：放素材走 `mediaImportLandings` + `insertImported`（撞上了往上抬一轨），
   切走 `split(clipID:at:)`，转场能不能放问 `transitionCapacity`，删和 ⌫ 同一口径（链接开着带上伙伴），
   素材 → 片段走 `clip(for:)`，生成 / 翻译字幕走面板上那同一个任务，导出走 `VideoEditExporter`。
   AI 多出来的只有两条：**给绝对值**（改入出点时起点不动；拖把手则是连起点一起挪）和**V1 往后推 / 往前拉**
   （`insert`、`ripple`，只动 V1 和它们的链接伙伴，别的轨、文字、滤镜、字幕不动 —— 写进了说明里）。
3. **排队**：改工程的调用按到达顺序一个接一个做（`AIToolRouter` 的 `tail`）。Claude 会在一条消息里并排发
   几个调用，不排队的话「接在 V1 最后」看谁先探完素材。`get_status` / `get_job`（最多等 30 秒）/ `cancel_job`
   不排队。
4. **看得见**：改工程之前 `AIEditorPresenter.prepareEditor` —— 切到剪辑页、主窗口 `orderFrontRegardless`
   （摆到最前面但**不激活 App**，键盘留在用户打字的对话框里）、等剪辑页把窗口的撤销管理器交给工程
   （没有它 AI 的改动进不了 ⌘Z）。每一步之后 `reveal`：选中改到的、播放头跳过去、时间线滚到看得见。
5. **不许弹模态框。** 用户在对话框那边，看不见也点不着，调用就一直挂着。「当前工程从没存过、又剪了东西」
   这类要问的，先回 `needs_confirmation`，用户同意丢掉之后清空、再走原来那条路（原来那条路就不会弹了）。
6. **只有动硬盘才问**（覆盖已有文件、读点名文件夹以外的文件）：`AIConfirmations` 发的令牌绑着具体那件事
   （`action` 字符串），一次有效、十分钟过期，换一件事拿它来不认。时间线上的改动一律不问。
7. **长任务回任务号**（客户端对一次调用大多只等一分钟）。结局在任务结束的**那一刻**记下（导出挂在
   `isExporting` 变回 false 上 —— `@Published` 在赋值前发，那时成品路径 / 错误已经写好；生成字幕挂在 `stage`
   上并且 `dropFirst`，订阅那一刻发的是上一次任务留下的结局）。AI 指定的分辨率只用于这一次
   （`settingsOverride`），不写回用户在面板上记住的设置。
8. **短 id**：UUID 前 8 位，撞了整体加长；收的时候前缀唯一就认。**轨道名** V1 = 主轨、V2… = 上层视频轨、
   A1… = 音频轨，和专业剪辑软件同一套叫法。
9. **AI 做出来的文件**放在「打开的文件夹」的 `SrtFlow/导出`、`SrtFlow/工程`（名字跟着 App 语言），没打开过
   文件夹就放在工程旁边，再没有就是「影片」。`open_folder` 不列根上的 `SrtFlow/`，免得把上次的成片当素材。

## 五、这一轮、停止、撤销这一轮

- **一轮按时间划分**：服务器看不到对话。AI 开始改工程时开一轮、存一份时间线快照；30 秒没有新调用算结束，
  横幅换成「改了 N 处 · 撤销这一轮」。
- **撤销这一轮** = 把时间线换回快照（一步，可以再 ⌘Z 回来）。AI 中途换了工程，快照跟着换成新工程开始时的样子。
- **停止**：取消在跑的导出 / 生成字幕 / 翻译；之后 AI 的调用一律回「用户按了停止」，直到它安静 10 秒 ——
  AI 收到拒绝会停下来问用户，用户再说话时新的一轮照常开。排在队里、还没轮到的改动也不做了。
- 横幅（`AIActivityBanner`）只订阅 `AISession`，不读工程，挂在主窗口 detail 的顶上。

## 六、「连接 AI」（设置 ⌘,）

| 客户端 | 配置 | 怎么改 | 为什么 |
| --- | --- | --- | --- |
| Claude 桌面版 | `~/Library/Application Support/Claude/claude_desktop_config.json` | 直接改（第一次改前备份成 `.srtflow-backup`） | 官方就是让用户改这个文件 |
| Claude Code | `~/.claude.json` | 走它自己的命令行 `claude mcp add --scope user`；找不到命令行就「复制一段话」 | 正在跑的 Claude Code 会整份重写这个文件，直接改会被冲掉 |
| Codex | `~/.codex/config.toml` | 直接改 `[mcp_servers.srtflow]`（先备份） | 桌面版和命令行共用一份，很少被程序重写 |

只动 `srtflow` 这一项，别的原样留着；文件格式不对就报错、一个字节都不写（`AIClientConfigFiles`，自检钉着）。
配置里写的是**这一份 App 包里**的小程序路径，状态里「连着另一份」= App 挪过位置或装过测试版，点一下重连。

## 七、守卫

`scripts/check-mcp.sh`（CI 第 4 组）：真起小程序，两代客户端各喂一遍（握手、清单、discover、版本错误、
工具调用转发、客户端名字、整数 id、App 没开）；AI 改时间线的规则；客户端配置的增删；文字 / 颜色参数；
字幕批量改；词表对账；打包脚本把小程序拷进 Helpers 并且先签它再签外层。

`checks/timeline-drag-wiring.sh` 的「落点单一」一节把 AI 放素材单独数：拖文件进来那套仍是恰好两处
（画框、落地），`AITimelineEdits.swift` 里恰好一处 —— 一处都没有就是 AI 另算了一份落点
（2026-09-27 反向验证：拿掉那一处调用，守卫当场红）。

## 八、人工回归清单（发版前在真机上走一遍）

- [ ] 设置里连接 Claude 桌面版 → 重启 Claude → 工具列表里有 srtflow 的 23 个工具。
- [ ] SrtFlow 没开时让 AI 调一个工具：SrtFlow 在后台启动，对话窗口不被挤下去，调用成功。
- [ ] 让 AI 打开一个文件夹、放几段素材：剪辑页被摆到最前面但键盘还在对话框里；每一步时间线滚过去、选中、
      预览跳到那一刻；顶上横幅「Claude 正在剪辑这个工程」。
- [ ] ⌘Z 一步退掉 AI 的一个调用；停 30 秒后横幅变成「改了 N 处」，「撤销这一轮」整轮退回，再 ⌘Z 又回来。
- [ ] 按「停止」：在跑的导出被取消，AI 下一个调用收到「用户按了停止」并停下来问你。
- [ ] 导出到已有同名文件：AI 先在对话里问，你同意后才覆盖；不同意就没动那个文件。
- [ ] 从没存过又剪了东西时让 AI 新建工程：AI 先问；SrtFlow 里**没有**弹任何对话框。
- [ ] 生成字幕 / 翻译：AI 拿到任务号，用 get_job 等到 done；时间线上的字幕和手动生成的一样。
- [ ] Codex 连接同一套走一遍；Claude Code 用「复制一段话」贴进去，它自己装好。
- [ ] 同时开两份 SrtFlow（正式版 + 测试版）：各自的 AI 只连自己那份。

## 九、已知不足（第一期）

- 「一轮」按 30 秒没动静划分：AI 想得久会被切成两轮。
- 「撤销这一轮」换回的是整条时间线：这一轮里用户自己动过的也会一起退回。
- 只有「看得见」一种模式；后台模式、访达选中、读文稿、整理文件在第二块（方案「分块」）。
- ChatGPT 聊天框连不上（只认网上的地址），用 Codex 代替；DeepSeek / Qwen 放第二期。
