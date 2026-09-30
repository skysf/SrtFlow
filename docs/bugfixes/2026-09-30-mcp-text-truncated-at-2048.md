# 2026-09-30 Claude Code 只读到总说明的前一半，edit_clip 的说明也被截了一截

## 症状

- 2026-09-30 的一个 Claude Code 会话（2.1.285，连着 SrtFlow Beta 0.18.0 的小程序）里，系统提示中 srtflow 的说明停在
  「Files that need no editing do not need a project: compress_videos, burn… [truncated]」—— 正好是第 2,048 个字符。
  后面的约定（时间、轨道名、坐标）和全部规矩：要用户点头时怎么问、`waiting_for_user` 要马上转告、没存过的工程存在哪要告诉用户、
  用户按了停止要停下来、只用给的文件、**只用 SrtFlow 的工具、不拿 ffmpeg 改素材、不从网上下载**（方案第 31 条），Claude Code 一句都没读到。
- 同一个会话里用 ToolSearch 加载 `edit_clip`，说明停在 `"none" … [truncated]`：声音场景的后半和标记那一句也没读到。
  main 上它是 2,074 字。
- 没有用户直接报过由它引起的错：不少规矩碰巧也写在工具说明或结果里（`set_view` 的说明里写着问一次、`find_audio` 的说明里有署名句、
  需要确认的结果自带 `next_step`、按了停止的报错写着「停下来问用户」）。但只写在总说明里的几条 —— 最要紧的是「只用 SrtFlow 的工具」——
  按现在的截法，在 Claude Code 里一直没生效。不知道 Claude Code 从哪个版本开始截。

## 根因

1. **Claude Code 对 MCP 的 `instructions` 和每个工具的 `description` 都只留前 2,048 个字符**（JavaScript 的字符串长度），多了静默截掉、
   末尾加「… [truncated]」。截总说明时只在它自己的调试日志里写一行，截工具说明什么都不记；官方文档没写这个上限；上游
   [anthropics/claude-code#87650](https://github.com/anthropics/claude-code/issues/87650) 按 not planned 关了。
   它还默认开着 tool search：会话开始时模型只看得到**工具名和总说明**，每个工具的完整定义用到才搜出来加载。
2. **总说明写成了一本手册**：五步流程、约定、九条规矩、配了 fal 再加一段，4,433 字（配了 fal 4,775）。前提是「客户端会把它放进模型的
   上下文」—— 对，但只放一截。写的时候以为越全越好，每加一条功能就往后面加一句。
3. **只有一条总预算**：`ProtocolChecks` 卡的是整份工具清单 ≤ 72,000 字（给没有按需加载的客户端算的上下文），**没有一条量的是
   客户端真正交给模型的那一份**：总说明多长、单个工具的说明多长都没人管。`edit_clip` 的说明随功能一点点长（画面放法、跟拍、去黑边、
   入场出场、音量曲线、声音场景、标记），过线 26 个字没人发现。

## 修复

- **总说明改成一份目录**（`Sources/SrtFlowMCPKit/MCPInstructions.swift`）：SrtFlow 是什么和平常的顺序（前 512 字，Codex 要自成一体）、
  五条要 AI **主动**做的规矩（开头问一次看着剪还是后台、改动不用问都能撤、没存过的工程存在哪要告诉用户、只用给的文件、只用 SrtFlow 的工具）、
  按需求分组的工具名（43 个全列，带上用户会说的词：9:16、水印、配乐……；配了 fal 多一行 generate_media）。
  1,836 字，配了 fal 1,940 字。三层怎么分写进 [AI 接口（MCP）](../architecture/ai-control-mcp.md) 第一节第 6 条。
- **挪出去的内容**：大多本来就在工具说明或结果里（见症状第三条，外加任务结果的「用 get_job 等」）。这次补的：
  - `get_timeline`：id 是短的、照原样用；带 `music_credits`。
  - `export_video`：导出之后把 `music_credits` 给用户放进视频简介。
  - `get_job`：一直等、别重开任务；看到 `waiting_for_user` 马上转告用户。
  - `recipes`：用户以后还想要这种风格时提 `save_recipe`。
  - `set_canvas`：换了画面比例，每段 `edit_clip fit=fill` 才铺满。
  - `generate_media`：不拿它重做用户已有的素材。
  - 需要确认的结果 `next_step` 加一句「令牌别猜、别复用」（App 的 `AIToolIO.needsConfirmation`：结果那一刻才用得上，放在结果里）。
  - 约定（时间是时间线的秒、`source_in` / `source_out` 是素材里的秒、V1 / A1、x / y 是比例）每个参数的说明里本来都有，目录里不再重复。
- **`edit_clip`**：说明末尾「Also: …」那一串（入场出场、音量曲线、声音场景、标记）挪进各自参数的说明（参数说明随工具一起加载、
  目前不截），2,074 → 1,676 字。
- **只用英文**（用户同一天定的）：清单里 3 处 12 个汉字 —— `recipes` 的「剪辑风格 / 预设风格」、`find_audio` 例子里的「悲伤」、
  `cut_speech` 例子里的「嗯、呃」—— 换成英文说法。AI 对用户会自己把 editing styles 译成「剪辑风格」。
- **整份清单没变长**：71,819 → 71,612。挪进工具说明的句子，用删掉和参数表重复的话抵掉（确认令牌的参数说明 9 个工具共用，写短；
  `generate_media` / `add_voiceover` 里重复参数表的时长和默认值删掉）。
- **守卫** `checks/MCP/CatalogTextChecks.swift`（新，跟着 `scripts/check-mcp.sh` 跑）：总说明（没配 / 配了提供方两种样子）和每个工具的
  说明 ≤ 2,048（按 UTF-16 数，同 Claude Code 的 JavaScript 长度）、总说明前 512 字点到 open_folder / get_timeline / look / export_video、
  目录里有清单的每个工具名（整词）、总说明和整份清单没有汉字。`ProtocolChecks` 里「总说明提到 music_credits / which one you follow」
  改成查 `export_video` / `recipes` 的说明；`ProviderChecks` 删掉「generate_media 说明 ≤ 2,800」那条（被每个工具 ≤ 2,048 取代，
  同一条规则只留一处），fal 那一行改查 generate_media / fal.ai / paid。

## 验证

- 数字（本机编小程序量）：总说明 1,836 / 1,940 字；最长的工具说明是 `edit_clip` 1,676 字；整份清单 71,612 字。
- **反向验证**：把 `Sources/SrtFlowMCPKit/` 整个换回 main 上的版本再跑新守卫，红 36 项 —— 总说明 4,433 / 4,775 字超长、前 512 字缺
  get_timeline / look / export_video（两种样子各 3 条）、目录缺 13 个工具名（两种样子各 13 条）、`edit_clip` 2,074 字超长、清单里有汉字；
  恢复修复后 144 项全绿，改动和换回之前逐字一致。
- `scripts/check-mcp.sh` 本机跑通：1,375 项全过。
- 人工（要装包、新开会话，这次没做）：装上这一版后新开一个 Claude Code 会话，系统提示里 srtflow 的说明结尾不是「… [truncated]」，
  ToolSearch 加载 `edit_clip` 也不是 —— 写进了架构文档第八节的人工回归清单。

## 教训 / 防回归

- **客户端怎么读，是接口的一部分**：我们送出去的字不等于模型读到的字。量要量模型真正拿到的那一份（系统提示里那段、ToolSearch 返回的定义），
  不能只看我们发了多少。
- **在按需加载的客户端里，总说明不是「所有规矩的家」**：它是目录。规矩按「要 AI 主动做 / 某个工具的事 / 某个结果出来那一刻」分三层放；
  往总说明里加一句之前先问它是不是第一种（[AI 接口（MCP）](../architecture/ai-control-mcp.md) 第一节第 6 条）。
- **一条总预算照不到单个的上限**：整份清单 ≤ 72,000 管不了「一个工具的说明 ≤ 2,048」，也管不了总说明。每一种上限各要一条守卫。
- 截断不报错、不留痕迹，所以守卫只能放在我们这边；上限变了（Claude Code 改了那个 2048）要跟着改 `claudeCodeTextLimit`。
