# 2026-08-09 生成后翻译报「Unable to Translate」：目标语言在隐藏状态下被敲定成了源语言

> ⚠️ **本案例的修复本身在同日复审里被抓出三个 P1 + 一个 P2**，见
> [2026-08-09-pr22-review-followups.md](2026-08-09-pr22-review-followups.md)：
> 这里写的检测阈值 0.45 低于实测错误模型的分数（`pick` 会把错误模型判成成功）、
> 「单候选直接采用」是零证据硬猜、metadata 查询绕开了可听合同，同批 UX 的
> `subtitleLayout` / `subtitleHidden` 还忘了升 formatVersion。
> **下面「验证」一节里的自检数字与结论按当时状态记录，不代表现行合同** ——
> 现行合同以 [architecture/subtitle-language-flow.md](../architecture/subtitle-language-flow.md)
> 与那份 follow-up 为准。

## 症状

英语系统的 Mac 上，视频编辑器里对一段英文视频：

1. 打开「Subtitles」面板（工程还没有字幕轨）——面板里**看不到任何目标语言**，
   只有「Generate from audio」区的 Spoken language 和一个
   「Translate after generating」勾选框。
2. 选 Spoken language = English (United States)，勾上 Translate after
   generating，点 Generate Subtitles。
3. 字幕生成成功，但面板同时出现两条红字：Translate 区一条
   「Unable to Translate」，生成区一条「Subtitles were generated, but
   translation failed: Unable to Translate」。**全程没有出现过模型下载确认**。
4. 此时 Translate 区的 Target language 显示「Chinese」——用户从没选过中文，
   于是把现象理解成「选中文提示无法翻译」。

## 根因

三层因素叠出来的，单看每一层都"没错"：

**根因 1：目标语言在不可见状态下被自动敲定。** 面板初开、没有字幕轨时，
`translationSection` 只渲染一句提示，Target language Picker 不渲染 —— 但
`reloadTargets()` 照样跑，`targetLanguageID` 照样被自动预选。而
「Translate after generating」勾选框直接消费这个从未露面的值。

**根因 2：2026-08-06 案例的修复让这个隐藏默认值恰好等于源语言。** 那次为了
治「默认翻译成阿拉伯语」，把排序改成「已装 → 系统首选 → 字母序」。本机系统
首选语言是 `["en-US", "zh-Hans-US"]`，于是源语言未知时自动预选 = **English**。
给英文视频生成英文字幕后顺便翻译，配置就是 en → en-Latn-US。

**根因 3：系统对一切配对失败只回一句话，且自我配对无物可下载。**
`LanguageAvailability.status(from: en, to: en)` 是 `unsupported`（自我配对
一律 unsupported，spike 实测）；提交给 `TranslationSession` 直接抛
`TranslationError.unsupportedLanguagePairing`。它的 `localizedDescription`
和 notInstalled、非法语言一样，全是通用的 **"Unable to Translate"**（NSError
code 恒为 1，实测），而 `TranslationErrorText.describe` 原样透传。又因为这种
失败**不需要下载任何东西**，「模型下载确认从没弹过」恰恰是这条路径的特征，
却被当成了「下载机制坏了」的证据。

失败之后源语言已知（"en"），`reloadTargets()` 重排把 en 从目标表剔除（自我
配对 unsupported），第一名落到系统首选第二位的中文 —— Picker 显示
「Chinese」+ 红字「Unable to Translate」，制造出「翻译中文失败」的假象。
诊断时曾按这个假象去查 en→zh：状态 `installed`、CLI 直译成功 —— 方向全反。

## 修复

四道防线，从「不让发生」到「发生了也说人话」：

1. **目标语言必须当着用户的面选定**（`SubtitleGenPanel`）：翻译区在没有
   字幕轨之前整个不渲染；「Translate after generating」勾上时在生成区内
   **展开可见的 Target language Picker**，勾选框在候选表为空时禁用。
   隐藏的自动预选值从此驱动不了任何翻译。
2. **提交前预检**（新增 `TranslationPreflight` + `SubtitleTranslationService`）：
   源语言已知时，同语种（maximal 化后语言码+文字系统相等；en ≍ en-Latn-US，
   zh-Hans ≠ zh-Hant）直接拦下并明说「字幕已经是X，无需翻译」；
   `LanguageAvailability` 判 unsupported 的配对同样拦下并点名两种语言。
3. **生成后顺便翻译遇到同语种按「跳过」处理**（`TranscriptionTask.translationSkipNote`）：
   如实说明、不算失败、也不伪装翻译发生过 —— 字幕生成的成功结局不再被
   一条注定失败的翻译拖成红字。
4. **错误文案按 cause 分类**（`TranslationErrorText`，macOS 26+ 用公开静态
   实例 + `~=`）：notInstalled / 配对不支持 / 识别不出语言各给一句能行动的
   话，通用「Unable to Translate」只剩兜底。

同一改动里落了本次的面板重构（详见
[architecture/subtitle-language-flow.md](../architecture/subtitle-language-flow.md)）：
生成区置顶、「Spoken language」改名「Source language」、默认值改为
**Auto-detect**（两段式检测：候选=素材元数据→系统首选→已装语言，探针转写
20s 按词置信度裁决，评分合同在 `SrtFlowCore/SubtitleLanguageDetection`）。

## 验证

- 错误指纹（spike + 独立探针，本机 macOS 26）：
  - `en→en-Latn-US` → `unsupportedLanguagePairing`，文案 "Unable to Translate"，
    与截图逐字一致；notInstalled（en→ja）同文案 —— 通用文案对定位毫无区分度。
  - `en→zh-Hans-CN` 状态 `installed`、直译成功 →「翻译中文失败」是假象。
  - 系统首选语言 `["en-US", "zh-Hans-US"]` → 复现了「隐藏默认=English、
    失败后显示 Chinese」的完整链条。
- 守卫（都做了反向验证，先红后绿）：
  - `scripts/check-translation-preflight.sh`（新）：8 条，撤掉同语种判定
    实测红 4 条。
  - `SrtFlowCoreChecks` 新增语言检测评分/裁决 12 条（总 653），把裁决阈值
    改坏实测红 4 条。
- `swift build --arch arm64` 零错误。
- GUI 冒烟（真实窗口，SrtFlowDev + 合成英文语音视频，按
  docs/testing/gui-smoke-testing.md，2026-08-09）：
  - 面板初开只有「Generate from audio」区，Source language 默认
    Auto-detect，看不到任何目标语言；勾选 Translate after generating
    当场展开可见的 Target language Picker，显示的正是 **English** ——
    原事故里那个隐藏的自动预选值，现在露面了。
  - 保持 English 目标直接生成（= 端到端复放原事故路径）：自动检测选中
    英语模型、生成 6 条**单行** cue，面板出现灰字 ⓘ「Subtitles are
    already in English (Singapore) — translation skipped.」+
    「Generated 6 cues.」—— 没有红字，没有「Unable to Translate」。
  - 有字幕后 Translate 区才出现，目标语言「Chinese (needs download)」
    的下载标注在源已知后是真话。
  - 同场冒烟顺带过了字幕轨眼睛（隐藏=预览消失+行灰显+图标橙色，恢复
    正常）与 cue 点选拖框（选中出框、拖动整体移动、位置在隐藏/显示
    往返后保持）。
  - 细节观察：自动检测在同为英语的候选（en_US/en_SG）间选了 en_SG ——
    同语言变体间的置信度差是噪声，裁决结果在语言层面等价，同语种
    判定按语言码+文字系统比较不受变体影响。

## 教训 / 防回归

1. **不可见的控件不许持有可生效的选择。** 「Picker 没渲染」和「值没被消费」
   是两回事 —— 状态在、消费者在，只是没人看得见。会被后台消费的选择必须
   和它的 UI 同生共死（不渲染就不参与），或者在消费点重新校验。
2. **上一次修复选出的"好默认值"，换一条路径就是事故值。** 2026-08-06 把
   默认目标排成系统首选，治好了「翻译外语字幕」；本次它在「生成自己语言的
   字幕」路径上恰好等于源语言。默认值策略要按**消费路径**逐条过，不是全局
   一份。
3. **通用错误文案会把诊断带反方向。** "Unable to Translate" 覆盖至少四种
   失败因；用户按字面把它安在了下一个看见的目标语言头上。对系统错误：能
   预检的在提交前拦掉，拦不掉的按 cause 翻成有区分度的话。
4. **「没弹下载确认」是证据，不是故障。** 无物可下载的失败路径天然无弹窗；
   把「预期内的沉默」误读成「下载机制坏了」浪费了一整段排查。列失败假设时
   要把每个假设的**可观测特征**（会弹什么、不会弹什么）一起列出来对账。
