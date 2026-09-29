# 2026-09-29 转写认不出语言时，AI 被叫去「面板里选」

## 症状

用户让另一个窗口里的 AI 驱动测试版 0.17.3 剪南极那条纪录片，AI 想知道几段素材里有没有人说话：

> transcribe（不指定语言，转时间线上的片段）失败：get_job 报 Couldn't confidently detect the spoken language. Pick it in the
> panel and generate again. 这些片段基本只有环境音，而且报错让人去「面板」选，AI 没有面板。绕法是加 language=en。

AI 自己猜到了绕法，但这句话本身是给点界面的人看的。`generate_subtitles` 不给语言时走同一条路，报的也是这句。

## 根因

转写和生成字幕是同一套（`TranscriptHarvester`），自动检测没认出语言时抛一个只带文字的错，文字是给面板写的。两个 AI 任务
把 `error.localizedDescription`（`generate_subtitles` 那一路是 `TranscriptionTask` 的 `.failed(String)`）原样交给 get_job，
认不出是哪一种错，也就没法换一句。

## 修复

1. 认不出语言单独一个错误类型 `LanguageUndetectedError`（`SubtitleGen/`，不挂在只在 macOS 26 上有的 TranscriptHarvester 里面，
   AI 那边和自检都认得出它）；面板上的文字不变。
2. `TranscriptionTask` 记下失败时的那个错（`failure`，`stage` 里只剩文字）。
3. `AIHarvestFailure.message(for:fallback:retry:)`：是这个错就回「可能只有音乐、环境声或者话太少；有人说话就带上 language
   （比如 en、zh-Hans）再调这个工具，没人说话就不用转了」，别的错原样。`transcribe`、`generate_subtitles` 的任务失败都经它。

另一句「没装任何语音模型，请手动选语言以便下载」本来就是 AI 照做得了的话（带上 language），没动。

## 验证

- `checks/MCP/TranscriptFormatChecks.swift`：认不出语言的错换成「call transcribe again with language」、不提 panel；别的错原样；
  面板那句还在。
- `scripts/check-mcp.sh` 扫描：检测处抛的是 `LanguageUndetectedError()`，两个任务的失败都经 `AIHarvestFailure.message(`。
  拿掉 generate_subtitles 那一处 → 红，恢复 → 绿。界面文案两张表 800 条齐全。
- 实机：测试版上让 AI 不带语言转写一段只有环境声的素材，get_job 的报错叫它带上 language。

## 教训 / 防回归

- **给界面写的报错不能原样交给 AI**：「去面板里选」「点下载」这类叫人去点哪儿的话，AI 那一路要换成它能照做的（给哪个参数、
  再调哪个工具）。
- **错误要能认出是哪一种**：只剩文字的错，调用方只能原样转述；要按种类换说法，就给它一个类型。
- 长期约束写在 [AI 接口（MCP）](../architecture/ai-control-mcp.md) 第四节第 25 条「失败时给 AI 它能照做的话」。
