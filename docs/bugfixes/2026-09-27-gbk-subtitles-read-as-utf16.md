# 2026-09-27 GBK 编码的字幕文件读出来是乱码（被当成 UTF-16）

## 症状

给 AI 做「读文稿」时，自检现造了一份 GBK 编码的中文讲稿，读回来是「뿎돌싴뗣ꎺ…」这样的乱码。顺着查下去，
读字幕文件的 `SubtitleLoader.load`（剪辑页挂字幕、字幕编辑面板、烧录队列三处都用它）和批量转换用的是同一个读法，
**GBK 编码的字幕文件在这三处都会读成乱码**：一串韩文、生僻汉字样的字，时间码也对不上，整份字幕不可用。
Windows 上导出的中文字幕、老的中文字幕站下载的 .srt 很多是 GBK。没有用户报过，大概是手边的字幕多半是 UTF-8。

## 根因

读法是「先试 UTF-8，不行试 UTF-16，再不行试 GBK」：

```swift
String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) ?? String(data: data, encoding: gbk)
```

GBK 的字节不是合法的 UTF-8，第一步会失败，这没问题。问题在第二步：Foundation 按 `.utf16` 解码时几乎**什么数据
都能解出来**。没有 BOM 就按大端两字节一个字去拼，多出来的最后一个单字节也不报错。所以 GBK 文件永远轮不到第三步，
直接变成了一串「合法」的 UTF-16 乱码。不带 BOM 的小端 UTF-16 也一样会被当成大端，读成乱码。

代码注释里写着「编码探测跟文档窗口那边保持一致」，批量转换那份（SrtFlowCore 的 `SubtitleConverter`）只有前两步，
连 GBK 都没有。同一条规则抄了两份，又都没有测过非 UTF-8 的文件。

## 修复

- 编码识别只剩一处：SrtFlowCore 的 `TextDecoding.decode`。`SubtitleLoader.load`、`SubtitleConverter.convertFile`、
  AI 的 `read_document` 都调它。
- 顺序改成：先看 BOM（UTF-8 / UTF-16 小端 / UTF-16 大端，BOM 不留在正文里）→ 严格 UTF-8 → **只有字节看起来像 UTF-16
  才按 UTF-16 解** → GBK（GB 18030）。「像 UTF-16」的判据是：字幕、讲稿里总有 ASCII 字符（时间码、数字、空格），
  UTF-16 里它们每个都留下一个 0 字节，而且全落在同一侧；GBK 和 UTF-8 的文本里没有 0 字节。

## 验证

- `checks/MCP/TextDecodingChecks.swift`（`scripts/check-mcp.sh`，CI 第 4 组）：一份 GBK 字幕按奇数、偶数字节各一份
  都读对；UTF-16 小端带 BOM、小端不带 BOM、大端不带 BOM 都读对；UTF-8 的 BOM 不留在正文里；纯 UTF-8 照旧。
- 反向验证：把 `decode` 换回老顺序，GBK 两条（45 字节、46 字节）和「小端不带 BOM」那条当场红，加上读文稿的 GBK
  那条一共 4 条；换回新顺序全过。
- 放在 MCP 自检里是因为那个二进制链接了整份 SrtFlowCore，又不用往只许降的 `SrtFlowCoreChecks/main.swift` 里加行。

## 教训 / 防回归

- **「解得出来」不等于「解对了」**：`.utf16` 几乎永远解得出来，放在候选列表中间就等于把后面的候选全堵死。
  宽容的解码器只能放在最后，或者先用特征（BOM、0 字节的分布）确认再用。
- 同一条规则抄了两份（字幕读取、批量转换），注释里还写着「保持一致」—— 结果两份都错、错法还不一样。
  现在只有 `TextDecoding` 一处，长期约束写在 [用户文本文件的编码](../architecture/text-file-encoding.md)。
- 读用户文件的自检要带非 UTF-8 的样本：这次是写新功能的自检时顺手造了一份 GBK 才撞出来的。
