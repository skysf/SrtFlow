# 2026-10-03 自动检测把英文旁白判成中文，转写出「3red65 days」

## 症状

2026-10-02 南极工程（报告见用户的「SrtFlow Bug 报告：南极纪录片剪辑」）：AI 调 `transcribe`，给了同一条英文旁白
（`VoiceOver_last.mp3`，男声，A3 上切成五段）的五个片段、不带 `language`。任务做完 `get_job` 报 `"language": "zh_CN"`，
转写是乱码的「英文」：「3red65 days」「rain forsts」「whides desits」。同样的片段带 `language: "en"` 再转一次，完全正确。

## 根因

自动检测（面板、`generate_subtitles`、`transcribe` 共用 `TranscriptHarvester.detectSourceLocale` → `SubtitleLanguageDetection.pick`）
是：同一段 20 秒探针让每个候选语言的模型各转一遍，**只比把握**（词时长加权的平均置信度，过 0.80 的取最高）。

- 中日韩的模型听到英文，会**照着声音写出拉丁字母的近似单词**，每个词还带着不低的置信度。本机缓存里的实例：
  中文模型转英文素材写出「And tarticaholes the record for the caldestempaturereature…」（0.711）、「discuraging」（0.804，已经过线）。
- 这段旁白停顿多、句末的词被拉长（识别器把停顿并进相邻的词，[案例](2026-09-26-pause-stretches-next-word.md)），
  而句末的词置信度偏低、按时长加权又被放大：英文模型这段只有 **0.873**（缓存里 35 个词原样算的）。
- 0.80 的门槛和「正确模型 0.91–1.00、错误模型 ≤ 0.74」是 2026-08-09 拿**合成语音**（`say`）标定的，真素材上两边都变了，
  中文模型的拉丁乱码略微超过英文模型，就赢了。**`pick` 从来不看转写出来的是不是那种语言的文字。**

顺带的第二份规则：`AITranscribeTool.cached()` 在缓存里有几种语言的转写时，按「词的平均置信度」另挑一份（没有门槛、也不核对），
和检测不是同一套判据 —— 重开 App 之后，它照样会挑中这份中文乱码。

## 修复

- `SubtitleLanguageDetection.pick` 先过一关 `isWrittenInOwnScript`：**中日韩的候选**（语言键的文字系统是简 / 繁 / 日 / 韩），
  转写出来的字母里中日韩的字（`SubtitleLineMeasure.isFullWidth`）要占 ≥ 25%（`minimumCJKShare`），不然不参赛；一个字母都没有也不算。
  本机缓存：中文模型转英文 0%，真中文 / 粤语 / 中英夹杂 43%–96%，25% 离两边都远。别的语言不核对（没见过它们写出别种文字的乱码）。
  只剩中文模型、写出来是拉丁乱码时判失败 → `LanguageUndetectedError` → AI 收到「带上 language 再调」（2026-09-29 那套），不是判成中文。
- `AITranscribeTool.cached()`：点名了语言、或者这次运行里刚检测出一种，直接用；否则缓存里有几种语言都交给同一个 `pick`，
  过不了就起任务重新检测。不再有第二份「挑哪种语言」的规则。

## 验证

- `SrtFlowCoreChecks` 的 `LanguageDetectionChecks`（`runScriptCheckCases`）：那段旁白真实的 35 个英文词（本机缓存原样抄的时间和置信度，分数 0.873）
  对一份把握 0.9 的中文模型拉丁乱码：两种顺序都判英文、只有中文模型时判失败；真中文对一份弱英文判中文；中英夹杂（汉字 2/3）算中文、
  汉字只占 1/11 不算；日文假名、韩文谚文算；全是数字不算；粤语 / 繁体核对、西语 / 英语不核对。原有用例里中日韩候选的词改成写中日韩的字
  （否则它们会在新那关就被挡掉，测不到门槛）。**反向验证**：去掉 `pick` 里那一关 → 「南极工程：英文旁白判成英文」两条和「只有中文模型判失败」红；恢复后全绿。
- `checks/project-file-wiring.sh`：`AITranscribeTool` 挑缓存语言走 `SubtitleLanguageDetection.pick`、不再有 `confidence > best`。反向验证：改回老写法 → 两条红。
- 人工回归加进 [字幕语言流](../architecture/subtitle-language-flow.md) 的清单：装了中文和英文模型的 Mac 上，英文旁白自动检测判英文。

## 教训 / 防回归

- **拿合成语音标定的阈值，在真素材上要重新量一次。** 0.91 的「正确模型下限」被停顿多的真旁白打破（0.873），而错误模型把别的语言写成
  拉丁字母时把握并不低 —— 单靠把握分不开两边，要加一个能把两种东西真正分开的特征（写出来的是不是那种文字）。
- **同一件事只许有一套判据**：检测用 `pick`、读缓存却用「平均置信度最高」，两份规则迟早给出两个答案。
