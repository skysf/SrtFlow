# 主轨数组乱序 → 图片/剪辑黑屏；竖版画中画默认布局爆出画布

日期：2026-08-08

## 症状

1. 图片从 Finder 拖进主轨：播放头停在它上面时**预览一片黑**，但选中框的位置
   和尺寸都正常；同一段挪到画中画轨就能显示。用户以为是「图片进不了主轨」。
2. 竖版图片当画中画：默认落在右上角，但**高度爆出画布底边**（下半截被裁掉），
   看起来「位置和大小都不对」，必须手动缩小。

## 根因

### 1. 主轨数组顺序 ≠ 时间顺序，A/B 合成轨被挤歪

`TimelineState.mainClips` 的下游全都假设「数组顺序 = 时间顺序」，但磁吸关掉后
有两个入口只改时间不改顺序：

- `liveMove` 的非磁吸分支只写 `timelineStart`；
- `relocate` 落主轨直接 `mainClips.append(moved)`。

而 `VideoEditCompositionBuilder` 主轨按**数组顺序**往 A/B 两条合成轨插段，
`insert` 的游标只会前进：一旦排在数组后面的段时间反而更早，
`insertTimeRange(at:)` 不是覆盖而是**插入** —— 同一条轨上已插好的段整体
往后挤。表现就是某些时刻黑屏、某些时刻画面错位。

复现（`checks/PreviewComposition` 新增用例的前身）：数组 `[白@8, 白@4, 静帧@0]`，
槽 0 的轨先插 8–12s、再回头插 0–5s，结果轨面变成
`实[0-5] 空[5-13] 实[13-17]` —— 10s 处实测亮度 **0.0**。

**画中画轨没有这个问题**，因为那条路径插入前有
`lane.clips.sorted(by: { $0.timelineStart < $1.timelineStart })` —— 同一个模式
一条路径写了排序、另一条没写，就是这次的病根。用户看到的「转成画中画就
好了」正是这条不对称。

连带伤害：auto 画布的 `renderSize(for:)` 取「数组第一段」的尺寸，乱序时画布
比例会突然横竖翻转；导出图的黑场补齐和 xfade 链同样按数组顺序算。

### 2. 画中画默认布局只按宽度算

九宫格默认布局 `宽 = 画布宽 × overlayFraction`，高度纯跟宽高比走。竖版素材
（手机截图 600×1080）在 16:9 画布上：40% 宽 → 高度 460 > 画布高 360，
默认就爆出画布。预览交互框、合成变换、导出九宫格表达式三处是同一个公式，
所以「框和画面对得上，但都不对劲」。

## 修复

不变量「主轨数组顺序 = 时间顺序」两头都做（老工程文件只有消费端能治）：

- `VideoEditTimelineEdits.swift`：新增 `TimelineState.sortMainClipsByStart()`
  （稳定排序，起点相同保持原相对顺序）。
- 改动入口维持：`liveMove` 收尾、`relocate` 收尾各调一次（磁吸开着时
  `packMain` 之后本来有序，幂等）。
- 打开工程归一：`VideoEditProjectIO.load` 里治好**已存盘**的乱序工程。
- 消费端防御：`VideoEditCompositionBuilder.build` 和 `VideoEditExportGraph.plan`
  入口各排一次 —— 和画中画轨的 `sorted` 对称。

画中画默认尺寸：新增 `OverlayAnchor.defaultSize(display:canvas:fraction:inset:)`
—— 按宽算完如果高度爆出画布（上下各留 2% inset），整体等比收进来。
三个消费点（`EditClip.defaultPlacement`、`fittingTransform` 九宫格分支、
导出 `scale=w:h:force_original_aspect_ratio=decrease:force_divisible_by=2`）
同账；横版素材算出来和原来逐像素一致，产物不变。

## 验证

- `scripts/check-preview-composition.sh` 新增两条（28 项全绿）：
  主轨数组乱序三时刻全亮；竖版画中画收进画布（亮度判据能区分收/没收）。
- `scripts/check-project-file.sh` 新增：乱序存盘 → 打开即归一、不丢段（122 项）。
- **三条守卫都做了反向验证**：撤掉对应修复，分别红成
  「10s 实测 0.0」「亮度 0.604（未收）」「顺序 [30,20]」，再恢复修复转绿。
- 全量：SrtFlowCoreChecks 644 项、freeze-frame、export-frame-rate、
  export-alpha-compositing、no-hardcoded-fps 全绿。
- 自检脚本是挑源文件编译的，`check-project-file` / `check-preview-composition` /
  `check-export-frame-rate` 的编译清单补了 `VideoEditTimelineEdits.swift`。

## 教训

- **同一份数据的两条消费路径，一条 sorted 一条没 sorted，就是定时炸弹**：
  对称的位置要么共享同一个入口，要么两边一起写、一起评审。
- 「数组顺序」这类**隐式不变量**要写成显式合同：改动入口维持 + 消费入口
  归一 + 打开文件时治旧账，三层缺一层就有一类文件/一条路径漏网。
- `insertTimeRange` 是**插入**不是覆盖 —— AVFoundation 轨道操作对时间乱序
  零容忍，游标式写入的循环必须先保证输入有序。
- 默认布局公式要拿**极端宽高比**过一遍：只按宽算的尺寸，竖版素材一定爆。
