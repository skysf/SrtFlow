# 界面语言：加西班牙语、法语、土耳其语，按系统自动选

> 2026-09-30 方案。用户提出加三种界面语言、软件按系统语言自动选，先讨论后拍板「按你的建议来」，
> 附带三条要求：代码结构化方便维护、能复用就复用、App 尽量轻量。
> 分三步走（第四节）。**当前状态以长期约束文档和代码为准**：
> [本地化](../architecture/localization.md)「加一种界面语言」一节、`Sources/SrtFlow/AppLanguage.swift`、
> `Sources/SrtFlow/Resources/*.lproj/`。

## 一、目标

- 界面能用西班牙语、法语、土耳其语显示，和现有的英文、简体中文一样完整。
- 用户什么都不用设：系统是哪种语言、App 就用哪种（包里没有的退回英文）。
- 加第 N 种语言的成本只有「一个 case + 一套表」，别处不用改。

## 二、先查清的事实（2026-09-30）

- **「按系统自动选」已经有了。** `AppLanguage` 默认就是 `.system`，SwiftUI 和 AppKit 按系统语言列表去包里找 `.lproj`；
  土耳其用户今天拿到英文，只因为包里没有 `tr.lproj`。加目录就够，不用写任何选语言的逻辑。
- 文案有 927 条（`Localizable.strings`）+ 4 条系统权限说明（`InfoPlist.strings`）。
- 架构上「两张表」写死在三处：`AppLanguage` 的几个 switch、覆盖守卫 `checks/LocalizationCoverage/main.swift`
  只比 en 和 zh-Hans、`scripts/check-mcp.sh` 点名两张 `InfoPlist.strings`。
- 检查器数值框已经跟着环境 locale 走（法语下显示、接受「1,5」）；代码里 114 处 `String(format:)` 是固定句点，
  同一界面会混着两种小数点 —— 小毛病，先不动。
- 界面文案没有做过大小写转换（土耳其语 İ / ı 的陷阱碰不到）。
- 没有 `.stringsdict`，复数都是「%lld Videos」这种写法：法语 0 和 1 算单数、土耳其语数字后不变复数。英文本来就这么凑的，不是新问题。
- 这只是**界面语言**。字幕生成 / 翻译 / 配音走内容语言，本来就不受影响；Kokoro 有法语和西语音色、没有土耳其语（退到 macOS 的声音）；
  MCP 的工具说明按规矩只用英文；风格卡是英文；README 保持中英双语。都不用动。

## 三、拍过的板

| 决定 | 口径 | 理由 |
| --- | --- | --- |
| 三种语言的代码 | 泛化的 `es` / `fr` / `tr`，不分 fr-CA、es-419 | macOS 会把地区变体匹配到泛化目录；分地区就是三倍的表、没人审 |
| 译文谁出 | 由 AI 出，术语表保持一致；**不做母语审校，AI 的译文直接算正式**（用户 2026-09-30：「我不做审核了，你翻译的我就直接认可」） | 用户和 AI 都不是母语者，但用户定了不找人审 |
| 要不要标 Beta | 不标：语言名就写 `Español` | 既然译文算正式，永远挂着「(Beta)」只会显得没做完；用户反馈来了按条改 |
| 先做哪种 | 西班牙语一种，在真窗口里看排版撞出多少问题、修完，再定另外两种照做还是缩范围 | 排版只在英文（和更短的中文）下验过；法 / 西比英文长两到三成，检查器是 220pt 的窄栏，英文已在缩写 |
| 加语言的机制 | 先一个 PR 把枚举和守卫改成支持任意多种语言、不带新表 | 机制和内容分开审；以后每种语言一个 PR |
| 复数 / 小数点 | 先照抄英文的写法 | 英文本来就这样；单独的事，别混进来 |

## 四、分刀

1. **机制**（PR #108，已合并）：`AppLanguage` 的 locale / AppKit 语言 / 有效语言代码都从 rawValue 推出来，音频库按语言选标题改看 `resolvedCode`；
   覆盖守卫按 `Resources/*.lproj/` 现场找表、每张译文表都和 en 对账（键集、空值、占位符、重复键），`InfoPlist.strings` 一并对账；
   `check-mcp.sh` 的访达用途说明扫每一张 `InfoPlist.strings`；架构文档补「加一种界面语言」。
2. **西班牙语**（PR #109，已合并）：`es.lproj` 两张表 + `case spanish = "es"`；系统语言设成英文、App 切西班牙语，逐面板看一遍排版，撞出来的按
   [检查器的排版](../architecture/inspector-layout.md) 的规矩修；结果报给用户。
3. **法语、土耳其语**：按第 2 步的结果定。

## 五、风险与要人工看的

- **翻译质量**：短词脱离上下文会歧义（Start / End / Clear / Size），剪辑术语（裁切、波纹、定格、ducking）要一致。
  翻之前先列术语表；没有母语审校这一道，用户的反馈就是唯一的纠错来源。
- **排版**：没有自动检查能抓文字撑破或截断（`checks/inspector-fits-width.sh` 只抓 Picker 的 `.fixedSize()`）。
  每种语言都要在真窗口里逐面板看；要在**系统语言是英文时**做（见本地化文档第五节）。
- **以后每个 PR 的本地化成本**：守卫要求每张表键集完全一致，新加一句文案就得同时给出每种语言的译文。这是永久的税，写 PR 的人（多半是代理）当场翻。

## 六、西班牙语在真窗口里看到的（2026-09-30）

系统语言英文、App 切 Español，进程内冒烟起 `SrtFlowDev` 拍四页 + 剪辑页选中一段的检查器（上下两屏）：

| 看到的 | 原因 | 处理 |
| --- | --- | --- |
| 侧栏「Incrustar subtítu…」「Conversión por l…」截断 | 宽档最窄 196pt，sidebar 的 List 把标签截成一行 | 标签允许折两行（`SidebarToolRow`，本 PR） |
| 转场卡片「Empuje a la izqui…」等三张截断 | 卡片宽度只放得下约 17 个字 | 译文改短：Empuje izquierda / Barrido abajo 这一类（#109） |
| 压缩页 CRF 滑杆右端「Archivo más pequeño」折成两行 | 英文「Smaller file」很短 | 译文改成「Menor tamaño」（#109） |
| 检查器动画两行标签「In」「Out」是英文，字体目录分组「Chinese」「Other」是英文 | 从没进过表：经参数转交的文案，守卫的手抄清单没有 `title:` 和位置参数 | [案例](../bugfixes/2026-09-30-animation-in-out-labels-never-localized.md)，守卫改成从声明推 |
| 烧录页文件行的两句提示被截断、字幕列空状态文字和按钮被裁掉右边 | **英文同尺寸（1180 宽）一样**，是内层 `HSplitView` 的 ideal 之和放不下时最后一栏溢出（[2026-08-12 案例](../bugfixes/2026-08-12-subtitle-editing-surfaces-smoke-fixes.md)的老问题） | 与语言无关，但西班牙语收尾时一起修了：[案例](../bugfixes/2026-10-01-burn-in-subtitle-column-clipped-at-default-width.md) |
| 录屏面板「24 fps · follows the project」、烧录列表「· N lines」是英文 | 带插值的键，守卫写明的盲区 | [案例](../bugfixes/2026-10-01-interpolated-keys-never-localized.md)，守卫对每个 `\(…)` 试 %lld / %@ |
| 滤镜库卡片「Verde azulado y…」截断 | 卡片只放得下约 15 个字 | 译文改成「Cian y naranja」 |

放得下的：检查器的速度 / 音量 / 声音场景 / 转场 / Transform / 裁切四个缩写（Izq Der Sup Inf）/ 动画；文字 / 形状 / 盖一块 / 滤镜的检查器；
导出面板、字幕生成面板、录屏面板、设置窗口、字幕列表、素材库三页；压缩页、烧录页的样式编辑、批量转换页；时间线工具栏。
第二轮（2026-09-30 晚）靠冒烟驱动新加的 `add` / `show` / `snapshot target` 三步拍的（PR #112）。法语、土耳其语照这个流程再看一遍。
