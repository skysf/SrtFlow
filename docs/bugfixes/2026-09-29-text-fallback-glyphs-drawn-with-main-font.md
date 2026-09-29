# 2026-09-29 主字体里没有的字（✨、汉字）画成乱码：回退字体的字形号拿主字体画了

> 用户用 AI 剪婚礼视频时撞上的（报告 BUG-10：`set_text text="It's a beautiful night ✨" font="Snell Roundhand"`，
> 第二行本该是 ✨，显示成一个像 `ĩ` 的字形）。手动加文字一样：任何主字体里没有的字都这样。长期约束写进了
> [画面文字](../architecture/text-overlays.md)「缺字回退」。

## 症状

标题用 Snell Roundhand（或任何不带 emoji / 汉字的拉丁字体），文字里带 ✨ 或汉字：预览和成片里那个字变成另一个
毫不相干的字形（拉丁字母、连字或空白）。换成带那个字的字体就正常。

## 根因

排版走 `CTFramesetter`，Core Text 遇到主字体里没有的字会按级联表**换一个字体**来排（✨ → Apple Color Emoji，
「甜」→ 楷体），那个 run 上带着换到的字体，`CTRunGetGlyphs` 给的字形号是**那个字体**的。`TextTypesetter.extractGlyphs`
只抄了字形号和位置，没记字体；`TextLayout` 只有一个 `font`（主字体），`TextDrawing.draw` 拿它一把画完所有字形 ——
Apple Color Emoji 里 ✨ 的字形号 326 到了 Snell Roundhand 里就是另一个字形。

为什么以前没发现：默认字体是苹方，几乎什么字都有；只有换成花体、手写体这类拉丁字体又打了 emoji / 汉字才露馅。

## 修复

- `TextLayoutFonts`（新文件 `VideoEditTextLayoutFonts.swift`）：一次排版用到的字体表，第 0 个是主字体，回退到的字体
  按出现顺序排在后面；每个字形记 `fontIndex`。`extractGlyphs` 读 run 的 `kCTFontAttributeName` 登记进表。
- `TextDrawing.draw`：连续同一字体的字形一批喂给 `CTFontDrawGlyphs(fonts[fontIndex])`。彩色字形（emoji，
  `traitColorGlyphs`）没有轮廓：描边那一道跳过它，渐变填充的裁剪那一道改成直接实画它（渐变刷不进去，emoji 本来就是彩色的）。
- 数字元件、包围盒照旧按主字体算（`layout.font` 现在是 `fonts.main`）。

## 验证

- `scripts/check-text-render.sh` 新增 `checks/TextRender/FontFallback.swift`：① 排版里 ✨ 的字形记的是 Apple Color Emoji、
  字形号就是它的，拉丁字母仍是主字体；② 用 Snell Roundhand 渲「✨」和把主字体直接设成 Apple Color Emoji 渲「✨」，
  墨迹交并比 ≥ 0.85，「甜」和它回退到的中文字体同理；③ 带描边时 ✨ 照样画出来，拉丁字母的描边照旧。
- 反向验证：`draw` 里把每一批都改回用主字体画，正好红三条（✨ 的交并比 0.03、「甜」0.0、带描边的 ✨ 0.03），
  排版那几条照旧绿（字形号本来就对，错的是画）；恢复后 160 项全绿。
- 成片和渲染图逐点重合那一组（第 1 组）照旧全过：导出走同一个 `TextRenderer.render`，回退字体一起进成片。

## 教训 / 防回归

- **排版给了谁的字形号，就得用谁画。** 字形号只在它自己的字体里有意义；一张排版表里可能有好几个字体。
- **默认字体太全会盖住这类 bug。** 自检要拿一款故意缺字的字体（花体 + emoji + 汉字）。
- **彩色字形不是轮廓。** 描边、裁剪这两道对它不成立，要么跳过要么实画，别让它在某一道里消失。
