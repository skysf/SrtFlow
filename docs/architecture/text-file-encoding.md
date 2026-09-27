# 用户文本文件的编码

> 2026-09-27 起生效的长期约束。案例：[GBK 编码的字幕文件读出来是乱码](../bugfixes/2026-09-27-gbk-subtitles-read-as-utf16.md)。

## 约束

1. **读用户给的文本文件（字幕、讲稿、笔记），编码识别一律走 SrtFlowCore 的 `TextDecoding.decode`**，不许在调用处
   自己写 `String(data:encoding:)` 的候选链。现在的调用方：`SubtitleLoader.load`（剪辑页挂字幕、字幕编辑面板、烧录
   队列）、`SubtitleConverter.convertFile`（批量转换）、`AIDocumentReader`（AI 的 read_document）。
2. 顺序是合同：**BOM → 严格 UTF-8 → 看起来像 UTF-16 才按 UTF-16 → GBK（GB 18030）**。
   - `String(data:encoding: .utf16)` 几乎什么数据都能「解出来」（没有 BOM 就按大端拼，单出来的最后一个字节也不报错），
     **不许无条件地放在 GBK 前面**，否则 GBK 永远轮不到。
   - 「看起来像 UTF-16」= 前 8KB 里至少五分之一的字节对有一侧是 0，另一侧几乎没有 0。字幕和讲稿里总有 ASCII 字符
     （时间码、数字、空格），UTF-16 里它们都会留下 0 字节；GBK 和 UTF-8 的文本里没有 0 字节。
   - BOM 不留在正文里。
3. 自己写出来的文件（导出的字幕、工程）一律写 UTF-8，不在这条约束里。

## 已知不足

- 全是汉字、一个 ASCII 字符都没有、又不带 BOM 的 UTF-16 文件认不出来，会按 GBK 解成乱码。Windows 写 UTF-16 都带
  BOM，这种文件极少见。
- Big5、Shift-JIS 等别的编码没有识别，会按 GBK 解。

## 回归

`checks/MCP/TextDecodingChecks.swift`（`scripts/check-mcp.sh`）：GBK 奇偶字节、UTF-16 带不带 BOM 和大小端、UTF-8 BOM。
