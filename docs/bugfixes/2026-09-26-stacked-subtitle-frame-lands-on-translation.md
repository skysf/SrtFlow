# 2026-09-26 原文、译文叠在一起时，点英文、改英文都落到中文上

## 症状

用户装上 0.14.0（字幕拆成两条独立轨），原文（英文）和译文（中文）在画面上叠成一块。时间线上点选
英文那一句（橙色块亮着），预览上的拖框却只框住**底下那行中文**；在预览上点英文、双击英文，选中和编辑的
都是中文那一句，「我无法修改和选择到英文字幕」。

## 根因

预览上的字幕块高度**一直量成 0**，这不是这次才坏的。

`BurnInSubtitleOverlay` 用 `GeometryReader` 把文本块的尺寸写进偏好值 `SubtitleBlockSizeKey`，外层
`onPreferenceChange` 收。这个键的合并写成了：

```swift
static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
```

SwiftUI 合并时，没写这个值的兄弟节点也会给出默认值 `.zero`，于是真正量出来的尺寸被后面的 `.zero`
盖掉，外层收到的永远是 0。拖框的矩形 `SubtitleFrameGeometry.frameRect` 取 `max(blockHeight, 24)`：
块高是 0 就退回 24 点、贴在块底。**单行字幕时 24 点正好差不多是一行** —— 框看起来是对的，从 2026-08-09
做拖框起就没人发现。

两条轨叠成一块之后（计划 S8），框只框选中那条轨的几行：按量出来的译文高度把整块切成上下两截。块高是 0，
整块被当成底部一行高，切不开（守卫条件不成立）就退回整块 —— 也就是底下那一行中文。于是：

- 选中英文，框画在中文上（用户截图里那样）；
- 预览上的点击热区也只有底下那一行，点中文 / 点英文都落到热区里「底下那一截 = 译文」；
- 双击出来的输入框编的也是译文。

**第一次修错了方向。** 看代码时先怀疑的是另一件事：量出来的高度存在根视图的 `@State` 字典里，经 `@Binding`
往下传，几块字幕各自在回报闭包里「读字典、改一格、整个写回」，而回报闭包挂在按值比较的文字视图上、可能是
旧的那一个 —— 旧字典写回去会把别的块的高度冲掉。据此把存储改成了这一层持有的引用类型，编好、用进程内冒烟
点了一遍：**点英文照样选中中文**。加日志一看，两个高度都是 0，而且只回报过一次 —— 根本不是「被冲掉」，
是从来没量到。根因在偏好值的合并上。引用类型那一改留下了（理由见下），但它不是这个 bug 的修复。

## 修复

- `SubtitleBlockSizeKey.reduce` 改成忽略默认值：`let next = nextValue(); if next != .zero { value = next }`
  （`Sources/SrtFlow/BurnInPreviewArea.swift`）。同一个文件夹里 `InlineEditorSizeKey` 早就是这么写的。
- 量出来的高度从根视图的 `@State` 挪进预览字幕层自己持有的 `SubtitleBlockMeasurements`（`ObservableObject`，
  `VideoEditPreviewSubtitleLayer.swift`）。理由：以前块高永远是 0、从来不变，根视图从没被它叫醒过；修好之后
  每换一句字幕块高就会变，还放在根视图上的话，每换一句整个编辑器重算一遍。放在只有它自己用的这一层，
  顺带去掉了「经 `@Binding` 读改写字典」那个隐患。
- 进程内冒烟的状态记录（`SmokeStateDump`）改成记下**选中的是哪几句**（id 前 8 位），以前只记个数 ——
  两条轨独立之后，选中的是原文还是译文得看得出来。

## 验证

用进程内冒烟（`scripts/gui-smoke/in-process/run.sh`，工程和素材都放在 scratchpad 里）搭了一份
「一段画面 + 英文两句 + 中文两句（各自的 ID）」的工程，播放头停在 2 秒（两条轨都有字）：

| | 块高 / 译文高（点） | 在预览上点英文那一行之后选中的 |
| --- | --- | --- |
| 修之前（`value = nextValue()`） | 0 / 0 | 中文那一句（`CFD8DA70`） |
| 修之后 | 30 / 15 | 英文那一句 —— 日志里拖框随即按「原文」那条轨定框 |

- 修之后那一轮的冒烟在点完第一下之后卡住了（不是这个 bug：见下面「顺带发现的两件事」），所以「修之后」那一格
  是从日志读的：高度回报和拖框按哪条轨定框都打在日志里，没有拿到那一轮的状态快照。
- 自动守卫：`checks/preference-reduce-keeps-value.sh`（扫描守卫，`check-all.sh` 第 1 组）—— 所有
  `PreferenceKey.reduce` 不许写成 `value = nextValue()`。**反向验证**：把这个键改回 `value = nextValue()`，
  守卫当场红、指到 `BurnInPreviewArea.swift:544`；改回来通过。
- 预览上的交互（点、双击、拖框、分开摆）自动化够不着，人工清单在
  [字幕轨可见性与布局](../architecture/subtitle-track-visibility-and-layout.md)「两条独立轨」。

### 顺带发现的两件事（没修，记在冒烟文档里）

- 冒烟用的 SrtFlowDev 在有 Touch Bar 的这台 Mac 上崩了两次：点完之后 AppKit 刷新 Touch Bar
  （`NSTouchBarFinderTouchBarsForProviders`），SwiftUI 给分段选择器（`SystemSegmentedControl`）量尺寸时在
  `DesignLibrary` 里空指针。正式版没报过；原因没查。
- 每次重编的 SrtFlowDev 在系统眼里都是新 App，它去跑仓库里（`~/Downloads` 下）的 `vendor/ffmpeg` 会触发
  访问「下载」文件夹的授权弹窗，探测 ffmpeg 的线程一直等在读管道上 —— 冒烟流程于是停住。

## 教训 / 防回归

- **量尺寸的偏好值，合并时别让默认值盖掉量出来的值**（扫描守卫钉着）。
- **「看起来对」可能是巧合**：24 点的保底高度恰好接近一行字，把「从来没量到」遮了一个多月；换成两行才露馅。
  验一个量出来的值，要用一个保底值蒙不对的样本（两行、字号大）。
- 先怀疑的原因（闭包旧、字典被冲掉）说得通，但改完一跑没用 —— 能跑就先跑、加日志看真实数值，比推理快。
