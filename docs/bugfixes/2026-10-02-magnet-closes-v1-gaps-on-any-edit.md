# 2026-10-02 磁吸开着时，改一条音量曲线就把整条 V1 的缝合上了

## 症状

用户让 AI（Claude 桌面版经 MCP，SrtFlow Beta 0.18.17）给南极纪录片配乐。工程的 V1 上有几处用户特意留的黑场缝
（1:22.5 的 1.3 秒、1:49.2 的 0.94 秒、2:01.9–2:34.5 的一大段）。AI 做的第一批改动全是别的轨上的事：切开 A3 上的旁白、
挪一段旁白、改 A2 上一段配乐的音量曲线、往 A9 放一首曲子、往 V2 放一段画面。之后发现：

- V1 上所有片段首尾相接，缝全没了：红毛猩猩 1:23.80 → 1:22.51、鲸鱼 1:50.15 → 1:47.97、Shot1 2:34.51 → 1:59.72（提前 34.8 秒）、
  最后一段 Shot4 提前 41 秒；
- 压在这些片段上的旁白、音效、字幕跟着挪了（`edit_clip` 只改了音量曲线，结果里却写着「linkage moved 97 items」），
  有的撞上了别的段被挤到别的轨（旁白 A3 → A1、雨林音效 A1 → A5）；没压在 V1 片段上的配乐不动，于是音画错开 1.3–2.2 秒；
- 跟着动的规矩看起来不一致：同一条旁白「365 days」那段跟着动了，「into the deepest rainforests」那段没动（它跨在两段 V1 上，
  两段被挪的量不一样）。

之后 `split_clip`、`edit_subtitles` 改一句字幕、往 V2 放素材、用户自己在界面里往 V1 加一段 Shot2，每一次都一样。打开工程、
`look` / `listen` / `transcribe` 不触发。AI 只能改工程文件、按 id 把位置一个个恢复成备份里的值。

## 根因

**磁吸是全 App 一份的开关，而 `perform` 每次收尾都排一遍 V1。**

1. 当时这台机器上 Beta 的磁吸是开着的：2026-10-01 起工具栏开关记在 UserDefaults（[剪辑页上记住的开关](../architecture/editor-remembered-toggles.md)），
   之前某次拨开过，就一直开着（会话里 `add_clips` 往 V2 放一段也把 V1 合拢了 —— 只有 `perform` 收尾的 `packMain` 能做到；
   报告之后用户把它关了，偏好里现在是 `magnetEnabled = 0`）。
2. 打开工程不排 V1（有意的：打开就改工程会标脏、进撤销栈），所以磁吸开着也能打开一个 V1 有缝的工程 —— 缝是磁吸关着时留的。
3. `VideoEditProject.perform` / `liveApply` 收尾写的是 `if magnetEnabled { next.packMain() }`：**不管这次改了什么**，磁吸开着就把 V1 从 0 起排紧。
   改字幕、改音量、往别的轨放东西，统统把整条 V1 合拢；联动（2026-10-02 起默认开）再按「V1 的画面挪了」把压在上面的东西跟着挪、撞上了让开。

更糟的是这条行为是**写进文档的**：editor-remembered-toggles.md 第一节写着「磁吸记住为开的一个后果：启动后打开一个主轨有缝的工程，
缝会在第一次改动时被合上 —— 和同一次运行里换工程是一样的行为」，人工回归清单里也是「第一次改动合拢」。当时只当成「记住开关」的
一个边角，没想到全局开关和工程内容之间的错配会在别的工程上爆。剪映把主轨磁吸记在**每个草稿里**（草稿 `config` 的
`maintrack_adsorb`；这台机器上 37 个 CapCut 草稿 15 个关、22 个开），就没有这个问题。

AI 那边也看不见：`get_timeline` 只报了联动开关、没报磁吸，结果里只有「联动挪了 97 样」，没有一句「V1 被磁吸排紧了」。

## 修复

用户拍板（2026-10-02）：**磁吸跟着工程走**，同剪映。

- `TimelineState.mainMagnet`：这个工程的磁吸开没开。进撤销栈、存进工程文件（按需写键，关着不写）；**老工程缺键 = 关** —— 打开工程永远不改工程，
  也不会因为这台机器上次拨开过磁吸，就在第一次编辑时把用户留的缝合上。旧版丢掉这个键只丢开关、成片一帧不变，不开新版本（同 `rowHeights` 的口径）。
- 新建工程（启动时那个空工程、⌘N、AI 的 `new_project`）用上次拨的值：`VideoEditProject.newTimeline()` 读 `EditorToggles.magnet`。记住的那个只当新建工程的默认。
- 工具栏的开关只走 `setMagnet`：记成新建工程的默认 + `perform { $0.mainMagnet = on }`（一步撤销；拨开时收尾把 V1 排紧，同以前）。
  `VideoEditProject.magnetEnabled` 只是给界面读的镜子，`state` 的 didSet 里对上（变了才写，工具栏不会被每次编辑叫醒）。
- **改别的永远不动 V1**：`perform` / `liveApply` 收尾改成 `MainMagnet.settle`（纯值，`VideoEditMainMagnet.swift`）—— 磁吸开着，**并且**这次改到了 V1 的排布
  （段的先后、起点、时长、转场、增删）或者磁吸是这次才打开的，才排紧。就算 V1 上本来有缝（手改过的工程文件：拨开磁吸那一步连开关一起进撤销栈，⌘Z 不会退出这种组合），改字幕、音量、别的轨也一段都不动。
- AI：`get_timeline` 带 `magnet`；改工程的工具（`add_clips` / `edit_clip` / `delete_items` / `cut_speech` / `cut_to_beat`）在磁吸挪了 V1 的时候结果里带
  `magnet: {moved, note}`（`TimelineLinkage.Report.magnetPacked` → `AILinkageReport.magnet`）。
- 腾行数：`VideoEditModels.swift` 和 `VideoEditProject.swift` 都在行数基线上 —— `CanvasRatio` 挪进 `VideoEditCanvasRatio.swift`（18 个自检脚本的清单跟着加），
  形状的默认大小挪进 `ShapeKind.defaultSize`，轨道默认行高的分派挪进 `TrackRowKind.defaultHeight`，两个基线都降了。

## 验证

- `scripts/check-timeline-snap.sh` 第 1g 组（`checks/TimelineSnap/Magnet.swift`）：磁吸关着裁 V1 不排；开着、V1 有缝，改配乐音量 / 改一句字幕 / 往 V2 放一段 /
  改 V1 一段的音量都不排；按 `perform` 收尾的顺序（磁吸 → 联动）走一遍南极工程那一步：V1 不动、联动什么都不跟、压在上面的旁白和字幕留在原位；
  裁 / 挪 / 加转场 / 多一段才排、报挪了几段；这次才拨开就排、拨关不排。**反向验证**：`needsPacking` 改回「磁吸开着就排」→ 10 条红
  （旁白和字幕从 13 秒被挪到 11 秒，正是报告里的样子）；恢复后 597 项全绿。
- `scripts/check-project-file.sh` 第 42 组（`checks/ProjectFile/MainMagnet.swift`）：关着不写键、缺键读作关、开着往返不丢、打开不排 V1、删掉键的老文件读作关。
  **反向验证**：缺键默认改成开 → 3 条红（含第 1 组的往返）；改成无条件写键 → 1 条红；恢复后 1162 项全绿。
- 接线守卫 `checks/timeline-drag-wiring/toggles.sh` 第 11f 节：镜子只读、state 变了对上、`setMagnet` 记默认并走 perform、`perform` / `liveApply` 只经
  `MainMagnet.settle` 且不再直接 `packMain`、新建工程走 `newTimeline`、`mainMagnet` 只在这几处被写、`get_timeline` 报磁吸、工具结果报磁吸；`linkage.sh` 12a 跟着改成
  「联动在 `MainMagnet.settle` 之后」。**反向验证**：`perform` 改回 `if magnetEnabled { next.packMain() }` → 三条红；在别处写一次 `mainMagnet` → 红。
- `swift build --arch arm64 --target SrtFlow` 编过、`scripts/check-guards.sh` 全绿。
- 人工回归见 [剪辑页上记住的开关](../architecture/editor-remembered-toggles.md) 第七节（磁吸那几条改了）。

## 教训 / 防回归

- **会改工程内容的开关是工程的属性，不是 App 的偏好。** 吸附、播放跟随只影响手感，记在全 App 一份没问题；磁吸决定 V1 上的东西在哪，
  全局记住它，就等于让上一个工程的设置去改下一个工程（长期约束写进 [剪辑页上记住的开关](../architecture/editor-remembered-toggles.md) 第一节）。
- **一次编辑只许改它碰到的东西。** 「每次收尾都排一遍」在磁吸从头开到尾的工程里看不出毛病（排紧的 V1 再排一遍不变），只有内容和开关错配时才炸 ——
  收尾的自动规则要先问「这次改到了它管的东西没有」。
- **写进文档的「后果」也要当 bug 审。** 「第一次改动合拢」当时被写成预期行为、进了人工回归清单，等于给 bug 盖了章。
- 给 AI 的结果要说出**它没要求、却发生了**的事：只报「联动挪了 97 样」，AI 花了几轮才发现是整条 V1 被合拢了。
