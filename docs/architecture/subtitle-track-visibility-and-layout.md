# 字幕轨的可见性与工程级布局：眼睛、点选拖框、单行默认

2026-08-09 三项字幕轨 UX（眼睛开关、cue 点选 + 预览拖框、生成默认单行）
及其同日复审（[bugfixes/2026-08-09-pr22-review-followups.md](../bugfixes/2026-08-09-pr22-review-followups.md)）
沉淀的长期约束。改 `VideoEditSubtitleDocuments` / `SubtitleFrameCanvas` /
`BurnInSubtitleOverlay` / `SubtitleLayout` / `EditSelection` / 分段默认值前必读。
语言流（自动检测/翻译预检）的姊妹合同见
[subtitle-language-flow.md](subtitle-language-flow.md)。

## 可见性（眼睛）

1. **预览与烧录共用一个收口**：`TimelineState.visibleSubtitleDocument(for:)`
   （`VideoEditSubtitleDocuments.swift`，checks/ProjectFile 编进自检）。
   隐藏 = 两边都得 nil，语义与其他轨道的眼睛一致。消费端不许绕开它直接读
   `subtitleDocument(for:)` 做渲染 —— 那个变体只归**数据面**
   （独立 .srt/.vtt 文件导出）使用，文件导出**故意**不受眼睛影响。
2. `subtitleHidden` 走宽容 Codable（缺键回退 false），**但它是 v6 字段**。
   > 这里原本写着「不升 formatVersion —— 它只是可见性，旧版丢掉它无损画面
   > 数据」。**那句话是错的**，2026-08-09 复审推翻：旧版打开后自动保存会把
   > 这个键删光，本来设了「不要烧字幕」的工程于是把字幕烧进了成片 ——
   > 这正是画面数据。可见性和布局一起进 v6，登记清单见
   > [video-edit-project-file.md](video-edit-project-file.md)。
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
5. **`subtitleLayout` 是 v6 字段**：它决定字幕的位置/换行宽度/字号，旧版丢掉
   它会直接改变导出画面。加字段时的判断标准见
   [video-edit-project-file.md](video-edit-project-file.md)。

## 三类选择互斥（剪辑 / 形状 / 字幕 cue）

1. **互斥规则只有一份，写在 `EditSelection`**（`VideoEditSelection.swift`）：
   三个字段全 `private(set)`，唯一改法是 `selectClips` / `selectShape` /
   `selectSubtitleCue`，每个都清另外两类。`VideoEditProject` 的
   `selectedClipIDs` / `selectedShapeID` / `selectedSubtitleCueID` 只是它的
   计算属性门面。
   > 原来的写法是「每个入口自己记得清一下别的」，散在两个 didSet 加一个函数
   > 里 —— 漏了 shape ↔ cue 这一对，先点形状再点 cue 就同时挂两套预览框
   > （2026-08-09 复审 P2）。**不许回到「调用方自觉」那种写法**，加第四类
   > 选择时同样只改 `EditSelection`。
2. **点空白 = 三类一起清**（`clearSelection()`）：预览空白与时间线空白是
   同一语义，两边都调它。
3. **切工程必须清三类**：`closeCurrentDocument` 调 `clearSelection()`。
   漏掉 cue 的话，新工程会带着上一条工程的 cue ID 开场。
4. **失效的 cue 选择自动摘掉**：清理挂在 `VideoEditProject.state` 的
   `didSet`（时间线所有写入的唯一入口），删字幕轨 / 外挂新 .srt / 重新生成
   换掉整轨 cue 身份时都会生效，不留悬空拖框。只在真选着 cue 时才遍历 ——
   拖布局框那种高频 `liveApply` 不额外付代价，**一步撤销的语义不受影响**。
5. 合同由 checks/ProjectFile 钉住（`EditSelection` 的六条互斥/清理用例），
   「有没有被接上」由 `scripts/check-project-file.sh` 末尾的接线守卫钉住
   （`VideoEditProject` 是 @MainActor App 类型，自检编不动它本体）。

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
- [ ] **选择互斥两向**：选中形状 → 点轨道上的 cue，形状框必须消失；
      选中 cue → 点形状，字幕拖框必须消失。任何时刻预览上只有一套框。
- [ ] **切工程**：选中 cue 后新建/打开另一个工程，新工程不许带着拖框开场。
- [ ] **删/换字幕轨**：选中 cue 后移除字幕或外挂一份新 .srt，拖框当场消失。
