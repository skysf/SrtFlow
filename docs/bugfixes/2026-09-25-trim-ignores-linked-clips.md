# 2026-09-25 裁切不跟链接：视频裁短了，链接的音频留在原长

## 症状

链接开着（工具栏的链条亮着），拉一段视频的右把手把它裁短，链接在一起的那段音频不动，
留在原来的长度上 —— 声音比画面多出一截。挪、切（⌘B）、删（⌫）都是两段一起的，唯独裁不是。
用户在第二轮编辑器问题里点名要修（和「多段一起裁」一起，单独一个 commit）。

## 根因

链接语义在四个入口里写了四遍，裁切那一份漏了：`commitDrag` / `deleteSelected` / `splitClip` /
`trimToPlayhead` 都按 `linkedClipIDs(of:)` 展开名单，把手的 `liveTrim` 直接
`state.update(id)` 只改被拉的那一段。素材范围的换算（`sourceStart` / `sourceDuration` 按
`speed` 走）也散在 `liveTrim` 和 `trimToPlayhead` 两处各写一份。

## 修复

新文件 `Sources/SrtFlow/VideoEditTimelineTrim.swift`：

- `TimelineState.trim(_:leading:by:)` 是**唯一一份**裁切算法（五种块各改各的字段）；
  `trimRange` 算一段的这一边能走多少；`trimGroup` 把一组成员的范围取交集再一起裁 ——
  **谁先到头整组一起停**，不会出现「视频伸到头了、音频还在走」的错位。
- `VideoEditProject.liveTrim` 的名单改成 `linkageEnabled ? linkedClipIDs(of:) : [id]`，走 `trimGroup`。
- `trimToPlayhead` 也改走 `trim(_:leading:by:)`，自己那份素材换算删掉。

多段一起裁（选中的剪辑 / 形状 / 文字 / cue 同一个量）建在同一个模型上，是下一个 commit。

## 验证

- `scripts/check-timeline-snap.sh` 第 1b 组（`checks/TimelineSnap/Trim.swift`）：一段的范围（素材
  开头 / 余量 / 最短时长）、`clamp` 取交集（交集为空 → 0）、**链接组一起裁**（音频没余量时视频也不许
  往右伸；一起往左缩同一个量；起点端一起退、素材起点一起回到 0）、混合一组各改各的字段。
  反向验证：把 `clamp` 改成不看范围 → 「音频没余量，视频也不许往右伸」等多条红；恢复后 382 项全过。
- `checks/timeline-drag-wiring.sh` 的 `trim.sh` 一节：`liveTrim` 必须带 `linkedClipIDs(of:)` 且走
  `trimGroup`，函数体里不许再自己改素材范围；全仓改素材范围的地方只许在 `TimelineTrim`（转场借余料
  那份渲染副本除外）。反向验证：把 `liveTrim` 的名单改回 `[id]` → 「没带上链接伙伴」红。
- 真窗口（进程内冒烟驱动）：链接开着拉视频右把手，链接的音频同步变短；见下一个 commit 的冒烟。

## 教训 / 防回归

- **同一条语义有几个入口，就有几份机会漏。** 链接的名单该由一个函数给（`linkedClipIDs`），每个入口
  都必须问它 —— 守卫按入口逐个钉。
- **裁切的算法只许一份**，并且和「整组一起停」放在同一个纯值文件里：这样多段一起裁、链接一起裁、
  裁到播放头三件事共用同一段代码，测一次三处都测到。长期约束见
  [拖动手势 §3.6](../architecture/timeline-drag-gestures.md)。
