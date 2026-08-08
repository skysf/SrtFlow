# 字幕轨的可见性与工程级布局：眼睛、点选拖框、单行默认

2026-08-09 三项字幕轨 UX（眼睛开关、cue 点选 + 预览拖框、生成默认单行）
沉淀的长期约束。改 `VideoEditSubtitleDocuments` / `SubtitleFrameCanvas` /
`BurnInSubtitleOverlay` / `SubtitleLayout` / 分段默认值前必读。
语言流（自动检测/翻译预检）的姊妹合同见
[subtitle-language-flow.md](subtitle-language-flow.md)。

## 可见性（眼睛）

1. **预览与烧录共用一个收口**：`TimelineState.visibleSubtitleDocument(for:)`
   （`VideoEditSubtitleDocuments.swift`，checks/ProjectFile 编进自检）。
   隐藏 = 两边都得 nil，语义与其他轨道的眼睛一致。消费端不许绕开它直接读
   `subtitleDocument(for:)` 做渲染 —— 那个变体只归**数据面**
   （独立 .srt/.vtt 文件导出）使用，文件导出**故意**不受眼睛影响。
2. `subtitleHidden` 走宽容 Codable（缺键回退 false，不升 formatVersion）：
   它只是可见性，旧版丢掉它无损画面数据。
3. 导出面板在轨道隐藏时要**说出「为什么没烧」**（eye.slash 提示），
   不许静默烧出无字幕的成片让用户猜。

## 工程级布局覆盖（SubtitleLayout）

1. **坐标系只有一个**：1080p 虚拟画布基准像素（`BurnInStyle` 同款）。
   预览按 `boxHeight / 1080` 换算，ASS 靠 PlayResY=1080 等比缩放 ——
   任何新消费端都必须换算到这个基准，不许引入第二种归一化。
2. **一份数值、两个渲染面**：预览 `BurnInSubtitleOverlay.layout` 与烧录
   `BurnInStyle.assStyle(layout:)` 消费同一个 `state.subtitleLayout`。
   合同由 SrtFlowCoreChecks（ASS 映射）+ checks/ProjectFile（持久化）钉住；
   两边像素级观感的一致性自动化够不着，见下面的人肉清单。
3. **覆盖一旦存在，锚定固定为底部中心**（ASS Alignment 2 + 非对称
   MarginL/R + MarginV）。全局样式的九宫格 position 从此不参与该工程排版；
   字体/颜色/描边等其余样式仍来自全局样式。字号走 `fontScale` 倍率，
   不改全局字号。
4. 拖框语义（用户决定）：**框体=移动、左右边=换行宽度、四角=等比字号**。
   上下边把手不存在 —— 块高由内容和字号决定，不是自由度。
   角把手的倍率按**手势起点快照**算绝对增量（ResizableFrameBox 同一纪律），
   限幅 `fontScaleRange`。
5. cue 点选与剪辑选择**互斥**（`selectSubtitleCueID` / `selectedClipIDs`
   谁被设置谁清对方）；点预览空白两个都清。

## 生成默认单行

- `SubtitleSegmentationConfig` 默认 `maxLineCount = 1`，参数集版本随之
  升到 2（进 GenerationSnapshot）。**改任何分段默认值必须同步升版本**，
  SrtFlowCoreChecks 有「默认单行 + 版本 2 + 超长句拆条不折行」三条守卫。
- 两行字幕仍然合法（外挂 SRT、手工编辑）：拖宽布局框是把两行收成一行的
  用户侧手段，分段器不追溯改既有字幕。

## 人肉回归清单（GUI 冒烟，自动化够不着）

- [ ] 字幕轨眼睛：点击后行灰显、预览字幕消失、再点恢复；隐藏状态存盘重开不丢。
- [ ] 隐藏状态导出：成片无字幕，导出面板出现「不会烧录」提示。
- [ ] 点轨道上的 cue：播放头跳进该条、cue 高亮、预览出现拖框。
- [ ] 拖框体：字幕整体移动；拖左右边：换行位置变（两行可收成一行）；
      拖角：字号等比变；松手一步撤销可回退。
- [ ] 调整后导出：烧录位置/宽度/字号与预览一致（同一段画面对比截图）。
- [ ] 自动检测 + 生成：新字幕全部单行。
