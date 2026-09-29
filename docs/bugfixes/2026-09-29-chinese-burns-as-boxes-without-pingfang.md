# 2026-09-29 没下载苹方的 Mac 上，拉丁字体的样式烧中文字幕是方框

## 症状

给「成片字幕比预览小」加的自检（`scripts/check-subtitle-burn-size.sh`）第一次上 CI，Helvetica 里的中文那两种红了：

> 南极冰山 [Helvetica 100]: preview 273×66 …, burned 210×61

210 × 61 是四个方框（Helvetica 的「没有这个字」的框），预览却照样是中文。本机（用户的机器）同一个用例预览、成片都是苹方、
一样大。也就是说：在这种 Mac 上，样式是英文字体（默认就是 Helvetica）时，烧进成片的中文字幕全是方框，而剪辑页、烧录页播放时、
AI 的 `look` 看到的都是正常的中文。

## 根因

1. Helvetica 里没有中文，两边都靠回退。预览（SwiftUI / CoreText）用 `CTFontCreateForString` 回退；烧录的 libass 用 CoreText
   字体提供方问同一个问题，再到**能列举的字体**里按族名找那个字体、读文件。
2. 苹方完整版是按需下载的字体资源（`/System/Library/AssetsV2/com_apple_MobileAsset_Font8/…/PingFang.ttc`）。用户的机器下载了，
   两边都回退到它；CI 的机器没下载，CoreText 回退到**系统界面用的私有那份**（`/System/Library/PrivateFrameworks/FontServices.framework/
   Resources/Reserved/PingFangUI.ttc`，文件里的族名是「.PingFang SC」这类带点的隐藏名）。预览画得出来；libass 在能列举的字体里找不到
   它，就用 Helvetica 画 —— 方框。
3. 按名字要「PingFang SC」拿到的也是私有那份，而且族名照样报「PingFang SC」（不带点）—— 所以「私有」只能看文件在哪，不能看族名。

## 修复

回退到的字体 libass 用不了时，**预览和烧录一起换成每台 Mac 都有的字体**；回退到的是公开的字体（下载了苹方的 Mac）就不换，
那些机器上什么都不变。

1. `SubtitleFallbackFont`（App）：`isPrivate` 看字体文件在不在 `/PrivateFrameworks/` 里（或者族名带点、没有文件）；`builtInFont`
   按「冬青黑体 → 黑体（简 / 繁）→ 冬青黑体日文 → Apple SD Gothic Neo」挑第一个字全都有的，这几个都在 `/System/Library/Fonts`。
2. `SubtitleFontScale.runs`：回退是私有字体的那几个字换成挑出来的内置字体（`burnFamily` 记下族名），预览照它画、按它的比例缩；
   `burnOverrides` 把这几截交给烧录。
3. `SubtitleASSText`（SrtFlowCore）：烧录的一句字里，那几截前面写 `\fn` 点名这个字体。逐词高亮的词后面是 `{\r}`，会把点名的字体
   一起清掉，所以高亮和点名一起写：每换一种样子先 `\r` 再加这一截的字体和高亮。没有要点名的字体时，产物和以前逐字一样。
   `BurnInWorkspace` 把 `burnOverrides` 交给 `assDocument`；导出字幕文件不点名（那是这台机器的替补字体）。

## 验证

- `scripts/check-subtitle-burn-size.sh` 把 Helvetica 里的中文两种加回来：本机走苹方（273 × 66 对 274 × 66），CI 走冬青黑体。
  另外三条每台 Mac 都一样的：按名字要到的苹方是私有的、中文挑到冬青黑体、韩文挑到 Apple SD Gothic Neo；每种都打出两边用了什么字体。
- 本机模拟「没下载苹方」（临时把苹方也当成私有）：预览、成片都换成冬青黑体，330 × 80 对 330 × 79、粗体 219 × 43 对 220 × 42，
  26 项全过；同时拿掉烧录那边的点名 → 成片回到苹方（274 px 宽），4 项红。恢复后全过。修之前的真凭据是 CI 那一次（方框）。
- `SrtFlowCoreChecks` 的 `checkFontOverrideASS`：没有点名时和以前逐字一样；只点名；点名和高亮写在同一个标签里；亮的词在点名的字
  里面时 `\r` 之后字体照样点名；`assDocument` 给了点名事件里就有、不给和以前一样。994 项全过。
- `checks/check-script-source-lists.sh`：`BurnInWorkspace` 多用了 `SubtitleFontScale`，编它的 6 个自检清单都补上了。

## 教训 / 防回归

- **「系统有这个字体」有两层**：CoreText 找得到，不等于 libass 找得到。系统私有的字体只给系统自己用；要交给别的渲染器的字体，
  得是公开、能列举的那一份。
- **认「私有」看文件在哪，不看名字**：按名字要到的私有那份，族名和公开那份一模一样。
- **下载型的字体会让同一个用例两台机器结果不同**：这次是 CI 先撞上的；用户的机器有苹方，自己永远撞不上。
- 长期约束写在 [字幕轨可见性与布局](../architecture/subtitle-track-visibility-and-layout.md)「画面上的布局」第 2 条。前一个案例：
  [成片里的字幕比预览小一截](2026-09-29-subtitle-preview-bigger-than-burn.md)。
