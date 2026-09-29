# 2026-09-29 预览上字幕的位置和行距和成片对不上：libass 的行框用 win 量度，预览用 hhea

## 症状

[成片里的字幕比预览小一截](2026-09-29-subtitle-preview-bigger-than-burn.md) 修完大小之后，`scripts/check-subtitle-burn-size.sh` 的输出里还留着一处：
100 号 Helvetica 正中对齐，「HHHH」字心预览在 y 532、成片在 540（1080p 画布），「big news」546 对 556。当时把它写成「已知差异」没修，
理由是只差几个像素。AI 靠 `look`（画的就是预览）挑字幕位置，预览和成片摆在两处不算小事，交接里要求查清楚。

查下来**不止那一处**。拿 vendor/ffmpeg 真烧一帧、预览那个视图离屏渲一张，逐字体逐对齐量字的外框上下沿（100 号、1080p 画布，正数 = 成片更靠下）：

| 字体 | 单行：底部 / 居中 / 顶部 | 两行的总高（预览 / 成片） |
| --- | --- | --- |
| Helvetica（**默认字体**） | +1 / +8 / +16 | 147 / 161（行距差 14 px） |
| Helvetica 粗体 56 号（**默认样式**） | 0 / +4 / +9 | 81 / 90（差 9 px） |
| Hiragino Sans GB | −8 / −1 / +6 | 151 / 165（差 14 px） |
| Songti SC（宋体） | 0 / 0 / 0 | 203 / 163（预览多 40 px） |
| Avenir Next、黑体、Arial、Times、Menlo、苹方、Georgia、Impact | ±2 以内 | ±1 |

单行底部对齐（默认样式的样子）没事，所以一直没人撞上；居中 / 顶部对齐、两行的字幕（原文 + 译文叠在一起就是两行）、用了 Hiragino / 宋体的
中文字幕都对不上。

## 根因

**两个渲染器排一行用的量度不是一套**（和上一个案例的字号是同一类毛病，那次只对了大小）：

- libass（VSFilter 口径）：行框的上下用字体 OS/2 表的 `usWinAscent` / `usWinDescent`，撑满字号 —— 一行高 = 字号，基线在行框顶下面
  `字号 × winAscent / (winAscent + winDescent)` 处；
- CoreText / SwiftUI：hhea 的 ascent / descent，**不含 leading**（实测：Heiti、Arial 的 leading 3 px、Hiragino 的 43 px 都没进行框）。

两套量度一样的字体（Avenir Next、苹方、黑体、Menlo）没有差；不一样的有。拿字体表算出来的预览该补的量，和实测对得上：

| 字体 | 上沿要下移 | 下沿要下移 | 居中（两者平均） | 行距要补 | 实测（单行 顶 / 底 / 居中，两行行距） |
| --- | --- | --- | --- | --- | --- |
| Helvetica 100 | +15.3 | +0.4 | +7.9 | +14.9 | +16 / +1 / +8，14 |
| Helvetica 粗体 56 | +8.9 | −0.1 | +4.4 | +9.0 | +9 / 0 / +4，9 |
| Hiragino Sans GB 100 | +6.1 | −7.8 | −0.9 | +14.0 | +6 / −8 / −1，14 |
| Songti SC 100 | −20 | +20 | 0 | **−40** | 预览两行多 40 |

两个 SwiftUI 的坑（都是量出来才知道的）：

1. **`.lineSpacing` 不认负数**：宋体的 hhea 行高（140）比 win 行高（100）大，要把行距收紧 40，写成 `.lineSpacing(-40)` 一点用没有（照样 280 高）；
   `Text(AttributedString)` 里的段落样式（`maximumLineHeight`、`lineHeightMultiple`）SwiftUI 也不认；macOS 26 的 `lineHeight` 能用、
   App 要支持 macOS 15。**一行一个 Text 放进 VStack、用它的间距**正负都认（240 = 2 × 140 − 40）。
2. **换行符不是字**：换行落在样式的字体（Helvetica）那一截里，第一版把它算进了 libass 那边的行框，Helvetica 遇到纯中文的两行，行高被高估
   5 px，预览就多出 5 px。

## 修复

- **`SubtitleLineMetrics`**（新，`Sources/SrtFlow/`）：一句字用到的每个字体（回退的也算，取最大的上下量度；只有换行的那一截不算），
  算出 libass 的行框和预览的行框，给出 `lineSpacing`（行距要补多少，可以是负的）和 `shift(row:)`（顶部 / 居中 / 底部对齐各要往下挪多少）。
- **`SubtitleFontScale`**：多暴露两样 —— `ascentShare`（win 量度里「上面」占几成）、`ctFont`（按字号取 CTFont）。
- **`BurnInSubtitleOverlay`**：一行一个 `Text` 放进 VStack（间距 = `lineSpacing`）；整块按对齐 `.offset(y:)` 挪一点 —— **只动画面、不动布局框**，
  拖框（`SubtitleFrameGeometry`）按边距和量出来的块高算，不看这一挪（块高现在更接近成片）。一句字用到的字体只算一遍
  （以前九份描边副本各算一遍）。
- 不动成片：烧录、以前导出的所有成片、别的播放器打开的 .ass 都是 libass 的样子（同上一个案例的取舍）。

## 验证

- 探针（vendor/ffmpeg 真烧 + 预览离屏渲）：13 种字体 × 5 种文字（单行、两行、中英混排一行 / 两行、纯中文两行）× 3 种对齐 = 195 组，
  修完**上下沿都在 ±2 px 以内、高度差 ≤ 3 px**。修之前量过一批小的（8 种字体 × 一行 / 两行 × 3 种对齐 = 48 组）：15 组超过 3 px，
  全在 Helvetica（100 号、粗体 56）和 Hiragino Sans GB 上，最大 31 px（Helvetica 两行顶部对齐，下沿）；宋体不在那一批里，
  第一版只补正的行距时量到它的两行差 40 px，才发现 `.lineSpacing` 不认负数。
- 新自检 `checks/SubtitleBurnSize/PositionChecks.swift`（`scripts/check-subtitle-burn-size.sh` 里，24 组 48 条）：Helvetica 100 号的一行 / 两行 / 中英混排、
  纯中文两行、默认样式（粗体 56）、宋体、Hiragino、Avenir Next（两套量度一样的，不许被挪），每组三种对齐，比预览和成片字的上沿和下沿（容差 3 px）。
  原有的 11 个大小用例的位置也顺带对上了（Helvetica「HHHH」正中 532 → 539，成片 540）。
- **反向验证**（每次只拆一处，90 条里红几条）：不挪位置 23 条红（Helvetica 居中 / 顶部：预览 501 对成片 510、63 对 80…）；
  不补行距 18 条；只认正的行距（宋体）4 条（预览 797 对成片 837）；把换行算成字 4 条（纯中文两行，预览 833 对成片 837）。恢复后 90 条全过。
- 回归面：剪辑页预览、AI 的 `look`、烧录页播放中的叠层是同一个视图；接口没变；性能计数没有新的视图类型（`checks/preview-perf-wiring.sh` 过）。

## 已知不足

- 逐词高亮放大的那个词：行框按不放大的量（「big news」100 号正中还差 2 px）。
- 一行太长自己折出来的行只补正的行距；折在哪儿 SwiftUI 和 libass 不一定一样（一直如此，和字号无关）。
- 空行不画（生成和编辑都不会留空行）。

## 教训 / 防回归

- **「一份数值、两个渲染面」要比位置，不能只比大小**：上一个案例只比了字的宽高，位置差被写成「已知差异」放着；这次一比，差的不是个位数像素，
  是宋体两行差 40 px、默认字体的两行距差 14%。「只差几个像素」要在几种字体、几种对齐上量过才敢这么写。
- 先用探针在一批字体上把量度模型和实测对一遍再动代码（`hhea` 是否含 leading、换行算不算字、SwiftUI 认不认负行距，都是对表才知道的）。
- 长期约束写在 [字幕轨可见性与布局](../architecture/subtitle-track-visibility-and-layout.md)「画面上的布局」第 2 条：预览画字幕只走
  `BurnInSubtitleOverlay`，字号按 libass 的口径、**行框也按 libass 的摆**（`SubtitleLineMetrics`）。前一个案例：
  [成片里的字幕比预览小一截](2026-09-29-subtitle-preview-bigger-than-burn.md)。
