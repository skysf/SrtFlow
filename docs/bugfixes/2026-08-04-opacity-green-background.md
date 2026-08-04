# 半透明图层让预览背景变绿：默认合成器的 backgroundColor 陷阱

- **日期**：2026-08-04
- **来源**：Transform 面板开发中自测发现，未发布即修复
- **相关**：[preview-free-transform](../architecture/preview-free-transform.md)

## 症状

给剪辑设不透明度 50% 后，预览里画面本身正确变暗，但**整个画布的背景从黑
变成暗绿色**。同一条时间线只做旋转/裁切（画面有透明角落、但图层整体不透明）
时背景是正常的黑。导出不受影响（ffmpeg 显式叠黑底）。

## 根因

AVFoundation 默认合成器有两条路径：图层全不透明时走快路径，
`instruction.backgroundColor` 正常生效（旋转露出的角落也是黑的）；
一旦某个 layer instruction 的**整体 opacity < 1**，就切到混合路径 ——
这条路径**不铺 backgroundColor**，直接在零填充的 YUV 缓冲上混合。
YUV 全零（Y=0, Cb=0, Cr=0）不是黑，是暗绿：中性色度应当是 128。

## 修复

`BlackBaseVideoFactory`（VideoEditCompositionBuilder.swift）：用 AVAssetWriter
生成 64×36 两帧纯黑 H.264 缓存在 `~/Library/Caches/SrtFlowPreview/`，
时间线上有任何半透明图层（Transform 不透明度、转场淡入淡出）时，把它
scaleTimeRange 拉满全程、放大铺满画布，垫在 `layer: Int.min` 当不透明底 ——
混合永远发生在真实的黑之上，backgroundColor 不再被指望。
不依赖 ffmpeg，缓存被系统清掉就重写一个。

## 验证

真实窗口：不透明度 50% → 画面减半、背景纯黑；再叠 30° 旋转 → 角落也是黑。
导出侧 ffmpeg 链（colorchannelmixer=aa）本来就叠在 color=black 上，抽帧比对
与预览一致。

## 教训

**`AVMutableVideoCompositionInstruction.backgroundColor` 只在「所有图层都
不透明」的快路径上可靠**。要在预览里做任何整层半透明（不透明度、淡入淡出），
就自己垫一层真实的不透明底，别指望背景色。零填充的 YUV 显示成绿色是这类
问题的指纹 —— 再见到「莫名的暗绿背景」，先查是不是有 alpha 走了混合路径。
