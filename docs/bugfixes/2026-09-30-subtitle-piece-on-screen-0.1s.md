# 2026-09-30 生成字幕切出 0.1 秒的一条「just」：太短只罚了个固定分、按说了多久算

## 症状

用户用 MCP 剪婚礼视频（报告 ISSUE-17）：Perfect 前 32 秒生成字幕，默认样式（字号 56）出来 12 行，其中
「just」11.22–11.317 只在屏上留 **0.1 秒**，前面的「Darling」10.6–11.137 也只有半秒；字号改成 36 重新生成变成 10 行
（「Darling」+「just dive right in」）。

## 根因

这一句转写出来是「Darling, just dive right in.」五个词 1.94 秒。窄画面（竖屏 + 字号 56）下一行只放得下两个词：

1. 按逗号分成「Darling,」和「just dive right in.」；「Darling,」在屏上留不到 1 秒是太短的小句，规则是并到旁边，
   可是并上整个小句「Darling just dive right in」一行放不下，**并不了就留着自己成条**。
2. 「just dive right in」也放不下，动态规划切两段：「just / dive right in」和「just dive / right in」的代价
   **只差 0.002**（前者长短更不均，后者两段都短各罚 0.5），前者赢了。太短的罚分是固定的 0.5，**按说了多久算、不按能在屏上留多久算**，
   0.18 秒的「just」和 0.66 秒的「just dive」罚的一样多，也和「切在停顿上」的 0.35 奖励一个量级。
3. 字号 36 时一行放得下三个词，「just dive right in」不用切，所以只剩「Darling」半秒那一条。

用真实的词时间在 `SubtitleSegmentationChecks` 里复现，8 个字号宽 / 12 个字号宽得到的正是报告里字号 56 / 36 的两种结果。

## 修复

`SubtitleBreaks`（SrtFlowCore）：

- **太短按能在屏上留多久罚，罚分随短的程度加重**（`shortPenalty`）：在屏上留不到 1 秒（`isTiny` 同一个判法）的按差多少罚，
  差一半罚 1.5、差九成罚 2.7；只有一个词的至少 1；说了不到 5/6 秒的轻罚 0.5 照旧。
- **小句太短又并不进去时，整句一起挑切法**：逗号处算好断点（`cutCost` 减 0.35，同停顿），每条按能留多久罚；
  比让那个小句自己成条、旁边的再各切各的好。放得下时照旧一条一个小句。
- 词表搬到 `SubtitleBreakWords.swift`（那个文件顶到 400 行了）。

结果：8 个字号宽 →「Darling just / dive right in」（0.8 / 1.6 秒）；12 个 →「Darling just dive / right in」（1.2 / 1.2 秒）；
放得下 →「Darling just dive right in」不变。

## 验证

- `SrtFlowCoreChecks` 的 `checkNarrowLinesStayReadable`：Perfect 0–32 秒的真实转写，8 / 12 / 30 个字号宽三档的切法，
  每条都放得下，单个词的条在屏上不短过 0.4 秒。**反向验证**：修复前跑，8 个字号宽得到「Darling / just / dive right in」、
  「just」0.18 秒，12 个字号宽得到「Darling / just dive right in」，3 条红；修复后 1,000 条全绿。
- 原有的断句用例（南极工程的真句子、中文、长句、缩写）不变，照样绿。

## 教训

- **罚分要按用户感受到的量算**：观众看的是这条在屏上留了多久，不是说了多久；两条切法代价只差 0.002 就说明罚分没在量该量的东西。
- **规则保不住时要退到整体最优，不要各自为政**：一条一个小句是首选，并不进去时它已经破了，该让整句一起挑。
- 验断句用真实转写的词时间，报告里的两种字号一次复现两档。
