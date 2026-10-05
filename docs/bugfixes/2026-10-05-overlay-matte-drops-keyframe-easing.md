# 2026-10-05 上层轨带缓动的关键帧，成片里动画中途边缘错开

## 症状

上层视频轨（V2 及以上）上带关键帧动画的段 —— 画中画滑入、照片推镜、缩放 —— 只要那一段的曲线不是线性（2026-09-30
起检查器能选曲线，AI 的 `set_keyframes` 没给 `easing` 时一律 easeInOut），导出的成片里动画进行到一半，画面和它该在的
位置错开：一边被切掉一截、露出下面那一层，另一边冒出一条黑边；带缓动的不透明度动画颜色也算偏。预览是对的，只有成片错。
动画两头对得上（曲线和直线的起点、终点一样），只在动的过程中露馅，看着只像「成片没有预览干净」。

没有用户报过：是做「剪辑美感」第二刀（关键帧加回弹 / 急停 / 弹簧，[方案](../plans/2026-10-05-editing-aesthetics.md)）时
读到预渲染那段代码撞见的。新曲线会冲过目标值，错位只会更大，所以先单独修。

## 根因

上层轨带关键帧的段导出时走 fill + matte 预渲染（[关键帧动画](../architecture/keyframe-animation.md)、
[导出预渲染复审](2026-08-05-export-prerender-review.md)）：

- fill 是这一段自己渲出来的，关键帧原样带着（含曲线）；
- matte 是一段 1 秒的白块素材拉成段长，关键帧要从原素材的源时间轴换到白块自己的源轴上重建。

`VideoEditPrerender.remappedAnimation` 重建时只抄了时间和值：`Keyframe(time:value:)` 的 `easing` 用了默认的 linear。
2026-09-30 给关键帧加缓动（PR #104，`2b1a36d`）时这一处没跟上 —— 于是 matte 按直线走、fill 按曲线走。ffmpeg 那边先按
matte 把 fill 除回真实色再叠：两者错开的地方，要么 matte 为 0 把画面藏掉，要么 fill 只有黑底却被 matte 当成了画面。

为什么一直没发现：

1. 缓动的回归只测了预览合成（`scripts/check-preview-composition.sh` B2 的缩放真合成），成片那一路没有一条带缓动的用例；
   上层轨 fill + matte 的真导出用例（`check-video-fade.sh` 的透明静帧、`check-export-alpha-compositing.sh` 的合成数学）
   都是线性的关键帧或者干脆不动。
2. 这是「从旧东西构造新东西漏字段」：`easing` 带默认值，漏写了编译器一声不吭 —— 和
   [分割丢了隐藏和音频库的键](2026-09-26-split-drops-hidden-and-library-key.md) 同一类。

## 修复

- 换轴重建挪成纯函数 `ClipAnimation.remapped(_:)`（`Sources/SrtFlow/VideoEditAnimation.swift`，和 `clipped` / `stretched`
  放在一起），六条轨的值和曲线原样带着。换轴是线性的（时间线时刻进出两条源轴），一段两头之间的比例不变，带着曲线过去
  matte 和 fill 动起来一模一样。
- `VideoEditPrerender.renderOverlay` 的 matte 改用它，删掉手写的 `remappedAnimation`。透明静帧那一路（matte 就是它自己的
  灰度片、关键帧原样照抄）本来就对，没动。

## 验证

- **真导出**：`scripts/check-video-fade.sh` 新增 `checks/VideoFade/EasedOverlay.swift`。白色主轨上一块黑（画布宽 0.25、
  高 0.5）的中心 x 在 4 秒里从 0.25 走到 0.75，曲线 easeIn；1 秒时按曲线在像素 8.5–24.5、按直线在 16–32：x = 12 只落在
  曲线的位置里（该黑），x = 28 只落在直线的位置里（该白）。预览（和预览同一个函数）和成片都量。
- **纯值**：`checks/ProjectFile/KeyframeEasing.swift`（`scripts/check-project-file.sh` 第 39 组）加 `remapped`：每条轨保曲线、
  按给的换算挪时刻、值原样、换轴之后同一个时间线时刻取到同一个值。
- **反向验证**（在 CI 上做，不在本机编，用户的规矩是重的自检交给 CI）：同样的守卫、`remapped` 故意不带曲线，推到一个不合并的
  草稿 PR（#160），结果见下一段；关掉草稿、删分支，修复版的 PR 全绿。
- 行数：`checks/VideoFade/main.swift` 643 → 624（第 6 组「预设擦除入场」原样挪进 `PresetWipe.swift` 给新用例腾地方，预览
  取像素的两个函数挪进 `Probes.swift` 两组共用），基线已改小。

反向验证的结果（草稿 PR #160，CI run 37319888165 / 37321142691，跑完关掉、删分支）：

- `video-fade`：110 条里红 2 条 —— 成片 x = 12 实测 1.0（matte 按直线还没走到，画面被藏掉、露出主轨的白），x = 28 实测 0.0
  （matte 已经在那儿、画面还没到，冒出黑）；预览那两点照样对（预览走的是带曲线的合成，本来就没错）。
- `project-file`：1223 条里红 3 条 —— `remapped` 两条保曲线、一条「同一时刻同一个值」。**最后这一条第一版取了 2 秒**
  （缓入缓出的正中间，曲线和直线都是 50），第一轮反向验证时它照样绿；改成四分之一处（曲线 6.25、直线 25）后第二轮才红。
  没红过的断言不算守卫 —— 曲线的样点别取在正中间。

## 教训 / 防回归

- **从旧关键帧构造新关键帧只走 `remapped` / `clipped` / `stretched`**，不手写 `Keyframe(time:value:)`：带默认值的字段漏写，
  编译器不吭声。已写进 [关键帧动画](../architecture/keyframe-animation.md)「缓动」一节。
- **给模型加一个影响画面的字段，回归要覆盖它进成片的每一条路**：预览、主轨导出、上层轨的 fill 和 matte。只测预览，
  「预览对、成片错」就溜过去了。
- 动画类的错位要在**动的过程中**量：两头对得上的错，取首尾帧永远是绿的；量曲线别取正中间（缓入缓出在那儿和直线一样）。
