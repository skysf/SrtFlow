# 2026-09-29 把两句字幕改成一句，挪进来的词不再逐词高亮；字幕换行宽度没法调

> 用户用 AI 剪婚礼视频时撞上的（报告 BUG-06、ISSUE-16）。长期约束写进了 [AI 接口（MCP）](../architecture/ai-control-mcp.md)
> 第四节第 36 条。

## 症状

1. `generate_subtitles` 生成「I found a love」（3.0–4.58）和「for me」（6.16–8.54）两句，AI 用 `edit_subtitles` 把第一句的字改成
   「I found a love, for me」、结尾改到 8.54、删掉第二句。`get_subtitles` 的 `lines_with_word_times` 还是全部行数，可开了逐词
   高亮之后「for me」不亮，只有原来那句的「found / a / love」亮。
2. 竖屏 9:16 上字号 33–44 时「I never knew you were the someone」一定折成两行，换行宽度约画面宽的 74%，没有参数能调。

## 根因

1. 改字走 `SubtitleTrackEditing.setText` → `SubtitleCueWords.realigned`：没改的字保住原来的时间，**新加进来的词没有时间**
   （它们的时间在被删掉的那一句里，而 AI 只有「改字」和「删句」两个动作）。界面上的「合并」（`mergeCues` +
   `SubtitleCueWords.merged`）会把两句的词拼起来，AI 调不到它。`get_subtitles` 只报「几句有词的时间」，看不出一句里有几个
   词没有。
2. 换行宽度 = 画面宽减去样式的左右边距（`marginHorizontal`，默认 80，ASS 画布单位：高 1080、宽按画幅），9:16 的画布只有
   608 宽，80 + 80 就占了 26%。`edit_subtitles style` 没有这一项。

## 修复

- `edit_subtitles` 加 `merge`：几组 id（每组两句以上、同一条轨、按顺序），走界面「合并」那份合同
  （`SubtitleTrackEditing.mergeCues`），字按顺序以空格拼、时间取并集、逐词时间拼起来；结果里 `merged` 给留下的那句的 id。
  工具说明写明：合并用 merge，改字把两句抄成一句会丢掉挪进来的词的时间。
- `get_subtitles` 每一行加 `timed_words`（这句里几个词知道自己的时间）。
- `edit_subtitles style` 加 `max_width`（一行最宽占画面宽的几成，0.3–1）：按这个工程的画幅换成左右边距落在工程自己的样式上
  （`AISubtitleStyleChange.horizontalMargin`，画布宽同 `assDocument` 的 PlayResX），`describe` 回读 `max_width`。生成字幕
  一行放多少（`SubtitleLineFit`）读的是同一份边距，跟着变。`burn_subtitles` 那一批不收它（文件各有各的画幅）。

## 验证

- `scripts/check-mcp.sh`：`ConfigChecks` 的 merge（两句各带词的时间 → 一句「I found a love for me」、6 个词都有时间、
  「me」落在拼好的字里第 19 位、时刻按新的开头换算、结尾 8.54、留下的是前一句的 id；只给一个 id 报错）；
  `SubtitleStyleChecks` 的 max_width（16:9 画布 1920 宽、9:16 画布 608 宽；0.9 → 左右各 96 / 30；默认边距 80 回读 0.92 / 0.74；
  超出范围报错；落到 9:16 工程的样式上是 30、describe 回读 0.9）。
- 反向验证：`apply` 里跳过 `mergeCues`、换算里把画幅写死成 16:9，正好红 11 条（合并那组 7 条：没并成一句、字没拼、
  留下的 id 空、词只剩 4 个、「me」的位置和时刻不对、结尾没并；9:16 那组 4 条：画布宽 1920、边距 96、回读 0.92、落到
  工程上是 96）；恢复后 1191 项全绿。

## 教训 / 防回归

- **界面有的动作 AI 也要有，别让它拿两个别的动作拼。** 拼出来的结果看着一样，附带的数据（词的时间）就丢了。
- **「几句有」和「每句里几个有」是两个数。** 报给 AI 的要是它能据此改动的那个。
- **画幅不同，同一个边距占的比例不同。** 给 AI 的参数按画面的比例说，换算放在知道画幅的那一层。
