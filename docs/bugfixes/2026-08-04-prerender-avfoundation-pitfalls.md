# 预渲染落地时的两个 AVFoundation 坑：空轨炸导出、背景永远不透明

- **日期**：2026-08-04
- **来源**：关键帧动画的导出预渲染开发中自测发现（抽帧自检当场红），未发布即修复
- **相关**：[keyframe-animation](../architecture/keyframe-animation.md)、
  [2026-08-04-opacity-green-background](2026-08-04-opacity-green-background.md)

## 一、合成里的空轨让 AVAssetExportSession 报 "Operation Stopped"

**症状**：预渲染（AVAssetExportSession + 预览的合成）一跑就失败，错误信息
只有一句 "Operation Stopped"。同一份合成丢给 AVPlayer 预览毫无问题。

**根因**："Operation Stopped" 是 `AVErrorInvalidVideoComposition`（-11841）
的表述。预览合成无条件建了主轨 A/B 两条视频轨和两条音频轨，单段场景下
其中几条**没有任何 segment**。AVPlayer 容忍空轨，导出会话不容忍。

**修复**：`build()` 收尾统一 `composition.removeTrack` 清掉
`segments.isEmpty` 的轨，audioMix 参数同步按剩余 trackID 过滤。

**教训**：**AVPlayer 能播 ≠ AVAssetExportSession 能导。** 播放器对合成的
畸形宽容得多；同一份合成要走导出，空轨、指令覆盖缺口这类"播放没事"的
毛病都会变成 -11841。合成要给导出用，收尾先做一次自净。

## 二、`backgroundColor` 的 alpha 被忽略，透明背景根本出不来

**症状**：画中画预渲染指望「透明背景 + ProRes 4444」输出带 alpha 的中间片；
抽帧自检显示角落 alpha = 1.0 —— 整幅不透明，背景是实心黑。

**根因**：Apple 文档明说 `AVMutableVideoCompositionInstruction.backgroundColor`
**只支持不透明色，alpha 分量被忽略**。默认合成器的输出永远是满幅不透明画面，
换 4444/HEVC-alpha 编码器也没用 —— 上游就没有透明像素。

**修复**：fill + matte 双渲染（VideoEditPrerender.swift）：内容压黑底渲一条，
纯白素材套同一份摆放/旋转/不透明度动画再渲一条当蒙版，ffmpeg `alphamerge`
合回 rgba。不透明度只烘进 matte（fill 保持全亮，否则压暗两次）；蒙版的
摆放基准固化成显式 placement、关键帧换算到蒙版自己的源时间轴。
行不通的 `transparentBackground` 参数当场删掉，不留误导。

**教训**：**默认合成器出不了 alpha，这是文档写明的边界**，别靠猜、别靠
换编码器绕。要带 alpha 的合成产物，要么自写合成器（重），要么 fill+matte
双渲染（轻，全部白嫖现成能力）。另外：先写「产物必须满足什么」的自检再
接管线（这次角落 alpha 的检查当场拦住了错误方案，没让它混进导出图）。
