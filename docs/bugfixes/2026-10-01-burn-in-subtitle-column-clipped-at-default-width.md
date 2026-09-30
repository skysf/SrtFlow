# 2026-10-01 烧录页默认窗口宽度下字幕列被裁掉右边、文件行的提示截成省略号

## 症状

烧录页在默认的 1180 宽窗口里：中间「字幕」列的空状态文字「The subtitle lines show up here, in step wi」
和「Open Subtitle File…」按钮右边被裁掉一截；底下文件行的两句提示各截成「Drop a video and its subtitle fi…」
「Files with matching names ar…」。英文、西班牙语一样，从 2026-08-12 字幕列加进来起就这样，
2026-09-30 验西班牙语排版时在截图里看见的（[方案第六节](../plans/2026-09-30-ui-languages.md)）。

## 根因

- 字幕列：内层 `HSplitView { 预览 | 字幕列 }` 的 ideal 之和（540 + 320）超过这一栏拿到的宽度（约 587）时，
  `HSplitView` 先把前面的栏压到 min（320），再让**最后一栏按 ideal 铺**（320），多出来的六十多点直接
  溢出、被裁 —— 就是 [2026-08-12 案例](2026-08-12-subtitle-editing-surfaces-smoke-fixes.md)说的「不保护最后一栏」，
  当时只解决了检查器被顶出窗口，字幕列自己的 ideal 没跟着收。
- 文件行：两句 caption 和按钮挤一行，没地方就各自截断；截断的提示比不显示还糟。

## 修复

- 字幕列的 `idealWidth` 收到和 `minWidth` 一样（252）：320 + 252 放得进 587，最后一栏不再溢出。
  窗口更宽时用户照样能拖到 460。
- 文件行的标题抽成 `BurnInFileListHeader`（`Sources/SrtFlow/BurnInFileListHeader.swift`），两句提示用
  `ViewThatFits` 按放不放得下决定显示两句、一句还是不显示；候选项 `fixedSize`，不许自己缩。
  顺带把 `BurnInView.swift` 从 610 行降到 596（基线跟着改小）。

## 验证

- 进程内冒烟起 SrtFlowDev，窗口 1180×860，`show section:burnIn` 切到烧录页拍图（新加的 `section:` 步骤）：
  英文和西班牙语下字幕列的空状态换行、按钮完整；文件行显示一句提示。1400 宽时英文显示两句、西班牙语一句。
- 没有自动化能盖住的：加进 [本地化](../architecture/localization.md) 第六节的人工回归清单（每种语言在默认窗口大小下每页看一遍）。

## 教训 / 防回归

- **`HSplitView` 里最后一栏的 ideal 要能和前面各栏的 min 一起放进最小可用宽度**，不然它一定被裁。
- 一行里放不下的提示，用 `ViewThatFits` 少显示一句，别让它截成省略号。
- 拍某一页的截图时窗口大小要和用户默认的一样（1180）：1400 宽的图看不出这个问题。
