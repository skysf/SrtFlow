# 2026-09-29 圆体（Yuanti SC）烧录字幕：英文变成「f=」「～=」，预览是好的

> 用户用 AI 剪婚礼视频时撞上的（报告 BUG-04、ISSUE-15）：`edit_subtitles style={"font":"Yuanti SC"}` 之后导出，成片里
> 「I found a love」只剩 `f=`、`～=` 之类的字形，中文照常；App 里预览完全正常。换成冬青黑体就好。
> 长期约束写进了 [画面文字](../architecture/text-overlays.md)「文字的字体表和字幕不是同一份」。

## 症状

字幕字体选圆体，烧出来的拉丁字母是别的字形（下面这一帧是仓库自带的 ffmpeg 直接烧的，样式和 App 写的一样）：
「I found a love」变成 `f=` 和 `～=`，「我找到了一份爱」正常，描边和阴影都在。冬青黑体两行都对。

## 根因

用户机器上 `~/Library/Fonts/Yuanti.ttc`（23 MB，和系统按需下载在 `/System/Library/AssetsV2/…` 的那份 79 MB 圆体**不是同一个
文件**；App 只扫 `~/Library/Fonts` 这几个目录，烧录用的、libass 装的都是这份）里 Regular / Bold 两个面的 cmap 表有三张子表：
(0,3) format 4、(3,1) format 4（同一张）和 (3,10) format 12。**format 12 那张是坏的**：声明长度 458，可 34 个分组按规范应该是
16 + 12 × 34 = 424；里面的映射也错位 —— 'I'（U+0049）映到字形 73，而 format 4 里 73 是 'f'；'我' 映到 25105，正好是
它的码位。Core Text 不用这张表（拿 format 4 的：'I' → 44，预览、`CTFontGetGlyphsForCharacters` 都对），FreeType 按
惯例优先用 UCS-4（3,10）那张，libass 于是拿错的字形号去画：拉丁字母全错，中文那些分组碰巧对得上。
fontTools 4.62 读这张表也直接报 `corrupt cmap table format 12`。

App 的字幕字体清单（`FontCatalog`）只收「文件可读 + CoreText 能解析」的字体，圆体两条都满足，就被列进「烧录能用」的
字体里；AI 的 `edit_subtitles` 也按这张表认字体。

## 修复

`FontCmapSanity`（新文件）：扫描字体清单时读每个字体的 cmap 表（`CTFontCopyTable`），做两件便宜的事 —— ① Unicode
子表（(0,x)、(3,1)、(3,10)）format 4 / 12 的长度自洽（format 12 必须正好 16 + 12 × 分组数）；② 几张 Unicode 子表对 ASCII
字母的映射一致。一个文件里**任一个面**不过（圆体的 Light 面是好的，Regular / Bold 坏；libass 装的是整个 .ttc，按粗细挑到坏面
就错），整个文件就不进字幕字体清单（`FontCatalog.scan` 里 `descriptors.allSatisfy { FontCmapSanity.isSafeForFreeType(…) }`）。
圆体因此从烧录页的字体列表和 AI 能用的字体里消失，`edit_subtitles style font=Yuanti SC` 收到「cannot be used for
subtitles … Fonts that work: …」。画面文字（Core Text 渲染）不受影响，圆体照样能用。

不修字体文件本身：改用户机器上的字体、或者给 libass 一份修过的拷贝，都比「不列出来」重得多。

## 验证

- `scripts/check-subtitle-burn-size.sh` 新增 `checks/SubtitleBurnSize/CmapSanityChecks.swift`：手造的 cmap 字节 ——
  两张一致的 Unicode 子表判安全；format 12 长度多 34 字节判不安全；format 12 的字母映射和 format 4 错一位判不安全；
  format 4 声明长度超出表判不安全；没有 Unicode 子表判不安全。真字体：Helvetica、Hiragino Sans GB 安全（烧录自检就用它们）；
  `~/Library/Fonts/Yuanti.ttc` 在时，Regular 面判不安全、`FontCatalog.scan()` 里没有这个文件（CI 没有这份，这几条跳过）。
  第一版按名字取字体（`CTFontCreateWithName("Yuanti SC")`）来断言，拿到的是系统那份好的，两条红了才发现有两个文件；
  自检的 `runCmapSanityChecks()` 一开始还写在判红的 `exit(1)` 后面 —— 红了也退 0，挪到前面才算数。
- `checks/project-file-wiring.sh`：扫描必须调 `FontCmapSanity.isSafeForFreeType(font)`。
- 反向验证：扫描里撤掉体检那一行，接线守卫红；体检里撤掉「format 12 长度要正好 16 + 12 × 分组数」那条，手造的那条红、
  圆体不进清单那条红（圆体 Regular 面本身仍被「几张子表字母映射不一致」那条判出 —— 两条规则各自都能抓到它）；恢复后
  102 项全绿。
- 手动：仓库自带的 ffmpeg 烧「I found a love / 我找到了一份爱」，圆体（粗 / 常规）英文是 `f=`、`～=`，冬青黑体正常
  （scratchpad 里的三张 PNG）。

## 教训 / 防回归

- **「CoreText 能解析」不等于「FreeType 能用」。** 两个引擎挑 cmap 子表的规矩不同，一张坏子表只会伤到其中一个。
  字幕清单答应的是「libass 真能用」，就得按 libass 的路子检查。
- **中文对、英文错，先怀疑字符映射表，不是字体缺字。** 缺字是画不出来（方框），映射错是画出别的字。
- **用户报的现象要在最小环境里重做一遍**：一个 ASS 文件 + 仓库的 ffmpeg，两分钟就定性，比在 App 里导出快得多。
