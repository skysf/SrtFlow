# 2026-10-02 「撤销这一轮」退不回 V1：音频字幕回了原位，V1 还合拢着

## 症状

用户让 AI（Claude 桌面版经 MCP，SrtFlow Beta 0.18.17）给南极纪录片配乐。AI 改了五处之后发现 V1 上的缝全被合上了
（另一个 bug，见 [磁吸开着时改一条音量曲线就把 V1 的缝合上](2026-10-02-magnet-closes-v1-gaps-on-any-edit.md)），于是调 `undo round=true` 想整轮退回。
退回之后把工程文件和备份逐字段比：**只有 V1 第 17–42 段的开始时间不同**，音频、字幕、文字全和备份一样 —— V1 停在合拢后的样子，
压在上面的旁白、音效、字幕却回到了原位，音画错开 1.3–35 秒，比不撤还糟（Shot1 的画面在 1:59.7，它的人声还在 2:34.5）。
同一份工程在测试副本上单步 `undo`（⌘Z）能把 V1 退回去，两种撤销结果不一致。最后只能从备份文件恢复。

## 根因

`AISession.undoRound`（横幅上的「撤销这一轮」和 AI 的 `undo round=true` 都走它）用 `project.perform { $0 = snapshot }` 换回快照。
`perform` 是「一次编辑」的收尾：先 `packMain`（磁吸开着时把 V1 排紧），再联动（V1 的画面挪了，压在上面的东西跟着挪）。当时磁吸开着：

1. 快照里 V1 有缝 → `packMain` 又把它排紧 → V1 和退回之前一样（排紧的）。
2. 联动比的是「退回之前（排紧的 V1）」和「排紧之后的快照」：V1 的画面一点没挪，什么也不跟；音频、字幕则被这次赋值直接换成了快照里的原位。

结果正好是用户看到的：只有 V1 不对。单步 ⌘Z 走 `applySnapshot`（`state = snapshot` 原样），不过磁吸、不过联动，所以退得回去。
「撤销这一轮」从 MCP 第一块（2026-09-27）起就这么写；磁吸默认关、联动当时也不存在，所以一直没人撞上 —— 直到磁吸被记住为开
（2026-10-01 起开关记在 UserDefaults）又碰上一个 V1 有缝的工程。

## 修复

- `VideoEditProject.restoreTimeline(_:)`：整份换回某一刻的时间线，一步撤销、**原样**换回。和 ⌘Z 走同一条收尾
  （抽成 `adopt`：换上快照、摘掉已经不在的选择、补转好的静帧、重建预览），不过磁吸、不过联动。
- `AISession.undoRound` 改调 `restoreTimeline`。
- `VideoEditProject.swift` 在行数基线上，「补转好的静帧」那段纯值挪进 `PendingStillRepair`（新文件，行为不变），基线跟着降。

## 验证

- 守卫 `checks/timeline-drag-wiring/linkage.sh` 第 12e 节：`restoreTimeline` 走 `adopt`、函数体里没有 `packMain` / `TimelineLinkage` / `perform`；
  `undoRound` 调 `restoreTimeline`、不调 `perform`。**反向验证**：把 `undoRound` 改回 `perform { $0 = snapshot }` → 两条红；
  在 `restoreTimeline` 里先 `packMain` 再换上 → 两条红；恢复后全绿。
- `swift build --arch arm64 --target SrtFlow` 编过。
- 人工回归（[AI 接口](../architecture/ai-control-mcp.md) 第八节新加一条）：磁吸开着、V1 有缝的工程，让 AI 改几处之后按「撤销这一轮」——
  V1 的缝和压在上面的东西一起回到原位；再 ⌘Z 回到改过的样子。

## 教训 / 防回归

- **「换回某一刻」不是一次编辑。** 编辑的收尾（磁吸、联动、补色）都是按「从 A 改到 B」推出来的规矩，套在「整份换回」上就会把快照再改一遍。
  整份换回只许走撤销那条收尾（长期约束写进 [AI 接口](../architecture/ai-control-mcp.md) 第五节）。
- **同一件事的两条路迟早分叉**：单步撤销和整轮撤销各写一份收尾，一份过磁吸一份不过，平时看不出来；这次抽成共用的 `adopt`。
- 开关的组合（磁吸开 × V1 有缝 × 整轮撤销）自检没覆盖：这类组合写进人工回归清单。
