# 2026-09-29 成片里的字幕比预览小一截：libass 把字号当行高，预览把字号当 em

## 症状

用户让另一个窗口里的 AI 驱动测试版 0.17.3 做验收实剪（素材A 南极 16:9、素材B 课程推广 9:16），那边的 AI 导出之后
拿 OCR 量字幕框：

> 成片字幕比预览小：OCR 量字幕框，22 秒处预览宽 0.42、成片 0.30；15 秒处 0.39 对 0.28，约为预览的 71%。

9:16 那条同样。影响的不只是剪辑页的预览：

- 剪辑页的预览、AI 的 `look`（`AIFrameComposer`）、烧录页**播放中**的叠层都用同一个视图 `BurnInSubtitleOverlay` 画字幕，
  全都比成片大。AI 按 `look` 看到的大小挑字号，挑出来的成片字就小了。
- 烧录页**停着**时显示的是 ffmpeg 真烧的一帧（`BurnInPreviewRenderer`），于是同一页上播放和暂停字的大小不一样。
- 生成字幕时「一行放得下几个字」（`SubtitleLineFit`）也按预览的大小算，以为放不下，断得比需要的碎。

从 2026-07-30 有这个叠层起就这样。架构文档里写着「两边像素级观感的一致性自动化够不着」，只留了一条人工清单，
用户平时多用 Helvetica 配英文（成片是预览的 85%，不并排看不出来），中文字幕才差到 71%。

## 根因

**同一个字号，两个渲染器量的不是一个东西。**

- 烧录用的 libass 照 VSFilter 的口径：先把字体的上下量度换成 OS/2 表的 `usWinAscent` / `usWinDescent`，再按
  「上下量度之和 = 字号」定大小（FreeType 的 `REAL_DIM`）。于是字的 em = 字号 × UPM / (usWinAscent + usWinDescent)。
- 预览的 `Font.custom(name, size:)`（CoreText）把字号当 em。

这个比例每个字体不一样（UPM / (winAscent + winDescent)，2026-09-29 从字体表算、再用 vendor/ffmpeg 真烧一帧量字高对过）：

| 字体 | UPM | winAscent | winDescent | 成片 / 预览 |
| --- | --- | --- | --- | --- |
| Helvetica | 2048 | 1946 | 461 | 0.851 |
| Helvetica-Bold（默认样式是粗体） | 2048 | 1966 | 475 | 0.839 |
| 苹方（常规 / 中粗） | 1000 | 1060 | 340 | 0.714 |
| Avenir Next | 1000 | 1000 | 366 | 0.732 |
| Hiragino Sans GB W3 / W6 | 1000 | 951 / 1032 | 211 / 208 | 0.861 / 0.806 |
| 黑体-简 | 1000 | 860 | 140 | 1.000 |

那边量到的 71% 就是苹方那一行：默认字体 Helvetica 里没有中文，两个渲染器都回退到苹方，libass 把苹方画成字号的 0.714。

## 修复

**改预览、不改成片**：烧录页停着时的真烧一帧、以前导出的所有成片、别的播放器打开 SrtFlow 写的 .ass，都是 libass 的大小；
改预览只让「看到的」对上「一直在出的」，改成片会让所有用户的字幕突然变大。

1. **`SubtitleFontScale`**（新）：每个字体的比例（按粗体 / 斜体选到的那一款量，粗体画的是家族里真的粗体 —— Hiragino Sans GB 的
   W6 和 W3 差 7%）；`runs(_:style:)` 把一段字按实际画它的字体切开：字体里没有的字照 CoreText 的回退找到那个字体（libass
   回退到的是同一个，按比例量出来一致）。接口只收整份 `BurnInStyle`，漏不掉粗体。
2. **`BurnInSubtitleOverlay`**：每一截按「字号 × 它那个字体的比例」画（逐词高亮亮着的那个词再乘放大倍数）。剪辑页预览、
   AI 的 `look`、烧录页播放中都是这个视图，一起对上。
3. **`SubtitleLineFit`**：一行放得下几个字按 `lineScale(style:)` 算（样式的字体和它的中文回退里画得大的那个，保守）。

## 验证

- **新自检** `scripts/check-subtitle-burn-size.sh`（第 3 组）：`BurnInSubtitleOverlay` 离屏渲一张，同样的字照导出那条路
  （`BurnInWorkspace` + 同一个 `subtitles=filename=…:fontsdir=…` 滤镜）用 vendor/ffmpeg 真烧一帧，量字的外框。九种：
  100 号不加粗（Helvetica 英文、Avenir Next 里的韩文（回退到 Apple SD Gothic Neo）、Avenir Next、黑体、Hiragino 中英混排、
  逐词高亮放大 1.2 倍）和默认样式（粗体 56 号底部居中：Helvetica 英文、Avenir Next 粗体里的韩文、Hiragino W6）。修好后字高差
  ≤ 1 px、字宽差 ≤ 2 px。用户撞上的那一种（Helvetica 里的中文回退到苹方）在本机量过：预览 273 × 66、成片 274 × 66（修之前预览
  385 × 93）。
- **CI 第一次跑红了**：自检最初测的就是 Helvetica 里的中文，CI 的机器上成片是 210 × 61 —— 四个方框。苹方完整版是按需下载的字体资源
  （`/System/Library/AssetsV2/…/PingFang.ttc`），CI 的机器没下载；CoreText 回退到系统私有的那份（`…/Reserved/PingFangUI.ttc`，
  族名是「.PingFang SC」），预览照样是中文，libass 却找不到能用的字体、画成方框。字号的比较在那儿没有意义，回退改用韩文测
  （Apple SD Gothic Neo 每台 Mac 都在 `/System/Library/Fonts`，比例 0.833 和 Avenir Next 的 0.732 差一成多：回退的那一截
  用错比例、不缩都会红）。
- **反向验证**：比例一律当 1（修之前）→ 19 项红 16 项（黑体两边都是 1.0，照样绿，对的），比如 Helvetica 里的中文预览 93 px 高、
  成片 66 px；只按常规那一款量、不管粗体 → Hiragino 粗体那一项红（预览 236 px 宽、成片 222 px）；回退的那一截按样式字体的比例缩 →
  两种韩文红（预览 310 px 宽、成片 353 px）。恢复后全过。
- 第一版只量了常规字体，100 号的六种全过；换成默认样式（粗体）一跑，Hiragino 差 6% —— 所以默认样式单独占了三种。
- 位置：默认样式（底部居中）预览和成片的字中心差 1–2 px；100 号正中时 Helvetica 英文预览高 8–10 px（libass 按 win 量度摆
  行框、SwiftUI 按 hhea），没改，写进了架构文档的已知差异。
- 实机：[字幕轨可见性与布局](../architecture/subtitle-track-visibility-and-layout.md) 人工清单里「导出后字号与预览一致」那一条。

## 已知不足

- **没下载苹方的 Mac 上，拉丁字体的样式烧中文字幕会是方框**（CI 的机器就是这样），而预览照样显示中文。用户自己的机器有苹方，没撞上；
  要修得让烧录在这种情况下也有字（比如给 libass 一个公共的中文字体、预览跟着用同一个），是另一件事，记在
  [字幕轨可见性与布局](../architecture/subtitle-track-visibility-and-layout.md)「画面上的布局」第 2 条。

## 教训 / 防回归

- **同一个数字在两个渲染器里可以是两种量**：「一份数值、两个渲染面」只保证输入一样，不保证画出来一样大。换渲染器的地方
  要真画一张比一比，不能只比参数。
- **「自动化够不着」要先试一下再写**：离屏渲一张视图、真烧一帧，几秒钟就能比大小；这句话 2026-08-09 写进架构文档，之后没人再想过加这个检查。
- **画字的不一定是样式里点名的那个字体**：中文回退、粗体选真粗体 —— 量「实际画它的那一款」。
- **样本要带上默认值**：默认样式是粗体，第一版的样本全是常规体，照样全绿。
- **自检用的字体要每台机器都有**：苹方是按需下载的，本机有、CI 没有，同一个用例一边绿一边红；挑用例前先看字体文件在哪。
- 长期约束写在 [字幕轨可见性与布局](../architecture/subtitle-track-visibility-and-layout.md)「画面上的布局」第 2 条：预览画字幕只走
  `BurnInSubtitleOverlay`，字号按 libass 的口径（`SubtitleFontScale`）。
