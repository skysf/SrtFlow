# 2026-10-03 透明 PNG 放到上层轨，透明的地方成了黑方块

## 症状

2026-10-02 南极工程：AI 画了两张透明 PNG 的圆环（`HUD_Ring_A.png` / `HUD_Ring_B.png`，1080×1080 RGBA，角上 alpha = 0），放在 V2 / V3 上叠在
Shot2 上面 —— 透明的地方显示成不透明的黑，整张图是一块黑方块盖在画面上。有没有关键帧（缩放、旋转、不透明度）都一样；淡出时整块一起变淡，
说明 alpha 整个丢了。台标、字幕条、HUD 这类图形叠加都用不了，AI 只好改用字符和线条拼圆环。

## 根因

三处，一处比一处藏得深：

1. **转码丢了 alpha**（主因）：图片一律经 `StillImageClipFactory` 转成 60 秒的静帧视频走普通剪辑管线，编码写死 `libx264 -pix_fmt yuv420p` ——
   没有 alpha 通道。透明的地方露出 PNG 里存的颜色（这两张是黑）。预览的默认合成器其实认 alpha（ProRes 4444 / HEVC 带 alpha 的源能透出下层，
   子代理在探针里验过），导出的叠加链也一路保着 alpha（`format=rgba`、`rotate c=black@0`、`overlay`），都是输入里就没有。
2. **默认合成器把源当预乘的用**：探针里直通 alpha 的 ProRes 4444，alpha 为 0 的地方存着白就透出白、50% 的绿是加上去而不是混进去 ——
   所以中间片必须**预乘**；而 ffmpeg 的 overlay 默认按直通混合，导出那边就得先反预乘（ffmpeg 8 起 `unpremultiply` 看帧上的 `alpha_mode`，
   不先 `setparams=alpha_mode=premultiplied` 它原样放过去）。实测不反预乘：50% 的绿在红底上成了 (126,63,0)，该是 (127,127,0)。
3. **带关键帧的上层轨段走 fill + matte 预渲染，matte 是一块纯白素材**：只管摆放框的 coverage × opacity，不管图自己的 alpha ——
   就算静帧带了 alpha，透明的地方在 matte 里照样是白，成片里照样是黑方块。

## 修复

- **只给真用到了透明的图转透明静帧**（`StillImageClipFactory`）：文件头带 alpha 通道（`hasAlphaChannel`）并且缩到长边 1024 后有像素不是全不透明
  （`usesTransparency`，转码那一刻在别的线程上解码）→ 预乘的 ProRes 4444（`alphaConversionArguments`：`format=rgba`、透明补边、`premultiply=inplace=1`、
  `yuva444p10le`）+ 一份灰度遮罩（`matteConversionArguments`：`alphaextract`，H.264）。带 alpha 通道其实全不透明的、没有 alpha 通道的照旧 H.264
  （透明静帧一张 1080×1080 约 30 MB，1.4 秒）。
- **起名只有 `StillAlphaNaming` 一份**：`-alpha-v1.mov`（+ `-matte.mp4`）、带 alpha 通道的不透明图 `-opaque-v1.mp4`；带 alpha 通道的图**不再认老名字**
  （老缓存里就是黑方块），打开老工程时重转一次；透明静帧连遮罩一起在才算命中。
- **认它只问 `EditClip.isAlphaStill`**：预览 `needsOpaqueBase` 垫黑底（透明处同样走混合路径，不垫底播放器里是暗绿）；`coversCanvasOpaquely` 排除它；
  导出 `ExportTransformChain`（从 `VideoEditExportGraph` 拆出来的 Transform 链）叠之前标明预乘、缩放完反预乘；`AnimatedClipPrerenderer.renderOverlay`
  的 matte 用它自己的遮罩（裁切、翻转、时间、关键帧照抄）。主轨上的透明静帧不用另做：主轨收尾 `format=yuv420p` 丢掉 alpha，预乘过的颜色就是压在黑底上。
- 腾行数：`VideoEditModels.swift` 的 `croppedDisplaySize` 挪进 `VideoEditClipCrop.swift`；导出图的 Transform 链整块挪进 `VideoEditExportTransform.swift`；
  `checks/VideoFade/main.swift` 的 `filterGraph` 挪进 `Probes.swift`。新文件进了 19 个自检脚本的清单（`checks/check-script-source-lists.sh` 算的）。

## 验证

- `scripts/check-still-clip-encode.sh`（`checks/StillClipEncode/Alpha.swift`，素材用 CoreGraphics 画）：哪张图算用到了透明（透明 / 带 alpha 通道全不透明 /
  没有 alpha 通道）；生产参数的真产物 —— ProRes 4444 带 alpha、帧数 120、全透明处 alpha 和颜色都是 0、半透明的绿是预乘过的 128、不透明处原色；遮罩透明处黑、
  半透明处灰、不透明处白；起名的合同；工厂按图挑对文件名、转完命中、透明图的老 H.264 缓存不再认、遮罩没了不算命中。**反向验证**：去掉 `premultiply` →
  「半透明处的绿是预乘过的」红（实测 255）；查缓存不看 alpha 通道 → 5 条红；恢复后 48 项全过。
- `scripts/check-video-fade.sh`（`checks/VideoFade/AlphaStill.swift`）：透明 PNG 经**生产的**工厂转成静帧放在白色主轨上 —— 预览（和预览同一个 builder）、
  静态的成片、带关键帧（fill + matte）的成片都是透明处白、不透明处黑；单独在 V1 时透明处黑；滤镜图里有预乘标记和反预乘。**反向验证**：去掉反预乘 → 滤镜图那条红；
  预渲染的 matte 改回纯白 → 「成片（带关键帧）透明处露出主轨的白」红（实测 0.0，正是黑方块）；恢复后 105 项全过。
- **自动化够不着的一条**：撤掉预览的垫黑底，上面的自检照样绿 —— 暗绿只在播放器的 YUV 输出里出现，取帧器出的是 BGRA。改成 `checks/project-file-wiring.sh`
  钉住垫底这一处（反向验证：去掉就红），并写进 [关键帧动画](../architecture/keyframe-animation.md) 的人工回归：真窗口里看一眼。
- 用户的两张圆环：生产参数转出来 29 MB、1.4 秒；遮罩 82 KB，透明处 0、圆环处 255。

## 教训 / 防回归

- **管线里每一级都保着 alpha，不等于产物有 alpha**：预览认、导出链认，偏偏第一步转码把它扔了 —— 查「透明没了」要从源头一级一级量。
- **预乘还是直通是数据的一部分**：同一份像素，两个消费者（AVFoundation 当预乘、ffmpeg 的 overlay 当直通）解释不同；中间片按其中一个定，另一个显式换算。
- **「合法的辅助素材」也要带上主素材的性质**：纯白 matte 对不透明的段是对的，对透明的段就是错的 —— 预渲染的每一路都要问一句「源自己有没有 alpha」。
- 长期约束写进 [定格 / 静帧管线](../architecture/freeze-frame.md) 第 4a3 节和 [关键帧动画](../architecture/keyframe-animation.md)「导出」。
