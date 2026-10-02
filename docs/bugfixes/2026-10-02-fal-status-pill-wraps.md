# 2026-10-02 状态行上「Downloading」小标折成两行

## 症状

真实冒烟时截图：编辑器窗口 1424 pt 宽，upscale 刚起步（Preparing 当前，五个小标都在）那一刻，
状态行右边的「Downloading」小标被挤成「Download-」「ing」两行，整行高了一截；Preparing 过去只剩四个小标之后又正常。

## 根因

`FalPhasePills` 的每个小标是 `Text` 加 capsule 背景，放在状态行的 `HStack` 里，左边是任务的那句话（`Text … lineLimit(2)`）。
地方不够时 SwiftUI 先压可压缩的：小标的 `Text` 没说不许折行，就被压窄、折成两行，而左边那句话反而没截。

## 修复

小标加 `.lineLimit(1)` + `.fixedSize()`：小标不折行、不被挤扁；地方不够时让左边那句话去截（它本来就 `truncationMode(.middle)`）。

## 验证

界面排版，自动化够不着：按 [视频 upscale](../architecture/video-upscale.md) 第四节的人工回归（把窗口缩到最小宽度、起一个 upscale、
看五个小标都在一行上）。截图对比在冒烟的 scratchpad 里（`smoke/out/shot-45.png`）。

## 教训 / 防回归

- 一行里有几个「不许变形」的小件和一句可以截的话，要**明说谁让步**：给小件 `fixedSize`，让话去截；不说的话 SwiftUI 会挑小件下手。
- 截图要按用户默认的窗口大小拍（同 [烧录页列被裁](2026-10-01-burn-in-subtitle-column-clipped-at-default-width.md)）：
  这次是 1424 宽才露出来的。
