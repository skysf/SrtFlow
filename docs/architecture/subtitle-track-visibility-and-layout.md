# 字幕轨的可见性与工程级布局：一个语言一条轨、点选拖框、单行默认

2026-08-09 三项字幕轨 UX（眼睛开关、cue 点选 + 预览拖框、生成默认单行）
及其同日复审（[bugfixes/2026-08-09-pr22-review-followups.md](../bugfixes/2026-08-09-pr22-review-followups.md)）
沉淀的长期约束。改 `VideoEditSubtitleDocuments` / `SubtitleFrameCanvas` /
`BurnInSubtitleOverlay` / `SubtitleLayout` / `EditSelection` / 分段默认值前必读。
语言流（自动检测/翻译预检）的姊妹合同见
[subtitle-language-flow.md](subtitle-language-flow.md)。

## 可见性：一个语言一条轨

1. **一个语言一条字幕轨，各自一只眼睛**（2026-08-09 用户拍板）。时间线上
   原文一行、有译文再来一行；显示什么由这两只眼睛**推导**：

   | 原文眼 | 译文眼 | 结果 |
   | --- | --- | --- |
   | 开 | 开 | 双语 |
   | 开 | 关 | 只有原文 |
   | 关 | 开 | 只有译文 |
   | 关 | 关 | 不显示、也不烧录 |

   > 这取代了字幕面板里的「Preview track（原文/译文/双语）」segmented
   > control。**那个选择器已删除，不许复活**（有扫描守卫）：显示什么不该是
   > 一个额外的模式，而是「哪几条轨看得见」的自然结果 —— 与主轨/画中画/
   > 音频的眼睛同一心智。
2. **看得见的就是会被烧进成片的。** 预览与烧录共用一个收口
   `TimelineState.visibleSubtitleDocument()`（推导在 `visibleSubtitleChoice`，
   `VideoEditSubtitleDocuments.swift`，checks/ProjectFile 编进自检）。
   导出面板只剩一个「要不要烧字幕」的开关，**不再选烧哪条轨** ——
   「只烧中文」= 关掉原文那只眼睛。
   > 代价（用户已接受）：不能「预览双语、只烧中文」，导出前先切眼睛。
   > 换来的是不用再向用户解释「为什么预览的和烧出来的不一样」。
   消费端不许绕开它直接读 `subtitleDocument(for:)` 做渲染 —— 那个变体只归
   **数据面**（独立 .srt/.vtt 文件导出）使用，文件导出**故意**不受眼睛影响。
3. **两条轨是镜像对，不是两份独立字幕。** 译文 cue 与原文**共 ID、共时间**，
   由 `LinkedSubtitleEditing` 强制同步（改时间/删除/拆分/合并都两轨一起）。
   所以时间线上两行的块天然对齐，点任意一行选中的是同一条 cue。
   **UI 不许承诺它给不了的独立性**：别做「只删译文的某一条」「只挪译文的
   时间」这类入口。
4. **只有原文 + 译文两条。** 多语言（N 条译文轨）**暂不做** —— `subtitleCompanion`
   只有一份 translation，要做得把它改成数组，翻译/烧录/文件导出矩阵全重做。
   再提要先问（2026-08-09 已问过，用户选了「就两条」）。
5. `subtitleHidden`（原文眼）走宽容 Codable（缺键回退 false），**是 v6 字段**；
   `translationHidden`（译文眼）**是 v7 字段**，因为烧录跟着眼睛走之后，它
   直接决定成片里有没有译文。
   > **v6 及更早的工程要迁移成「译文轨隐藏」**（`VideoEditProjectIO.load`
   > 按 `formatVersion < 7` 判断）：那些版本的默认预览/烧录就是「只有原文」
   > （预览轨选择是运行时状态、默认 .original；烧录默认 Original text）。
   > 缺键回退 false 会把老工程的成片**悄悄变成双语** —— 升级不该改变谁已经
   > 做好的片子。用户之后点一下眼睛把译文放出来，那是他的显式选择。
   > `subtitleHidden` 这里原本写着「不升 formatVersion —— 它只是可见性，
   > 旧版丢掉它无损画面数据」。**那句话是错的**，2026-08-09 复审推翻：
   > 旧版打开后自动保存会把这个键删光，本来设了「不要烧字幕」的工程于是把
   > 字幕烧进了成片 —— 这正是画面数据。登记清单见
   > [video-edit-project-file.md](video-edit-project-file.md)。
6. 导出面板在**所有**字幕轨都隐藏时要说出「为什么没烧」（eye.slash 提示），
   开着时如实报出这次会烧哪几条，不许静默烧出与预览不一致的成片。

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

## 选择模型：点选互斥 / 框选混选（剪辑 / 形状 / 字幕 cue）

> 2026-08-12 随鼠标框选调整：**点选**仍然三类互斥，**框选**可以一次选中三类。
> 手势侧的约束见 [timeline-drag-gestures.md](timeline-drag-gestures.md) 的
> 「框选」一节，这里只写选择模型本身。

1. **规则只有一份，写在 `EditSelection`**（`VideoEditSelection.swift`）：
   三个字段（`clipIDs` / `shapeIDs` / `subtitleCueIDs`，都是集合）全
   `private(set)`，点选的唯一改法是 `selectClips` / `selectShape` /
   `selectSubtitleCue`，每个都清另外两类；框选走 `selectBox`，三类一起写。
   `VideoEditProject` 的 `selectedClipIDs` / `selectedShapeIDs` /
   `selectedSubtitleCueIDs` 只是它的计算属性门面。
   > 原来的写法是「每个入口自己记得清一下别的」，散在两个 didSet 加一个函数
   > 里 —— 漏了 shape ↔ cue 这一对，先点形状再点 cue 就同时挂两套预览框
   > （2026-08-09 复审 P2）。**不许回到「调用方自觉」那种写法**，加第四类
   > 选择时同样只改 `EditSelection`。
2. **「预览上最多一套框」换了个地方守，没有消失**：预览只认
   `soleClipID` / `soleShapeID` / `soleSubtitleCueID` —— 三类加起来正好选中
   一个时才有主角，多选或混选一律不画框（与以前「多选剪辑时不画框」一致）。
   **不许**在预览层各自再写一遍「要是还选着别的就不画」，写两遍迟早分叉。
3. **标记（marker）对所有人仍然互斥**，框选无条件清掉它（空框也清）。它的
   互斥从来不是为了画框，是为了 ⌫：删除只有一个入口，"选中的是标记" 和
   "选中的是整段" 必须互斥，否则点了段上的标记再按 ⌫ 删掉的是整段素材。
4. **点空白 = 三类一起清**（`clearSelection()`）：预览空白与时间线空白是
   同一语义，两边都调它。
5. **切工程必须清三类**：`closeCurrentDocument` 调 `clearSelection()`。
   漏掉 cue 的话，新工程会带着上一条工程的 cue ID 开场。
6. **失效的 cue 选择自动摘掉**：清理挂在 `VideoEditProject.state` 的
   `didSet`（时间线所有写入的唯一入口），删字幕轨 / 外挂新 .srt / 重新生成
   换掉整轨 cue 身份时都会生效，不留悬空拖框。只在真选着 cue 时才遍历 ——
   拖布局框那种高频 `liveApply` 不额外付代价，**一步撤销的语义不受影响**。
7. 合同由 checks/ProjectFile 钉住（`EditSelection` 的点选互斥 / 框选混选 /
   清理用例），「有没有被接上」由 `scripts/check-project-file.sh` 末尾的接线
   守卫钉住（`VideoEditProject` 是 @MainActor App 类型，自检编不动它本体）。

## 生成默认单行

- `SubtitleSegmentationConfig` 默认 `maxLineCount = 1`，参数集版本随之
  升到 2（进 GenerationSnapshot）。**改任何分段默认值必须同步升版本**，
  SrtFlowCoreChecks 有「默认单行 + 版本 2 + 超长句拆条不折行」三条守卫。
- 两行字幕仍然合法（外挂 SRT、手工编辑）：拖宽布局框是把两行收成一行的
  用户侧手段，分段器不追溯改既有字幕。

## 人肉回归清单（GUI 冒烟，自动化够不着）

- [ ] **两条轨各自的眼睛**：有译文时时间线上是两行；关原文 → 预览只剩译文，
      关译文 → 只剩原文，两只都关 → 预览无字幕且导出面板出现「不会烧录」提示；
      隐藏状态存盘重开不丢。
- [ ] **烧录跟着眼睛**：关掉原文那只眼睛后导出，成片里只有译文（抽帧核对）。
- [ ] **打开 v6 老工程（带译文）**：译文轨默认是隐藏的，预览/烧录与升级前
      一致（只有原文）—— 升级不许把谁的成片变成双语。
- [ ] 点轨道上的 cue：播放头跳进该条、cue 高亮、预览出现拖框。
- [ ] 拖框体：字幕整体移动；拖左右边：换行位置变（两行可收成一行）；
      拖角：字号等比变；松手一步撤销可回退。
- [ ] 调整后导出：烧录位置/宽度/字号与预览一致（同一段画面对比截图）。
- [ ] 自动检测 + 生成：新字幕全部单行。
- [ ] **点选互斥两向**：选中形状 → 点轨道上的 cue，形状框必须消失；
      选中 cue → 点形状，字幕拖框必须消失。任何时刻预览上只有一套框。
- [ ] **框选混选后预览不画框**：拉框同时选中剪辑 + cue，预览上一套框都不该有；
      再点其中一条 cue（只剩它一个）拖框回来。
- [ ] **从 cue 起手拖动**：拖一条选中的 cue，整片选择（剪辑/形状/其他 cue）
      跟着走同一个位移；译文轨那一行的块同步移动（两轨镜像），一步撤销可回退。
- [ ] **隐藏的字幕轨不可编辑**：关掉原文（或译文）那只眼睛后，那一行的块
      点不中、也拖不动 —— 隐藏 = 不可编辑，灰显只是它的观感。
- [ ] **手势被打断后还能再拖**：拖 cue 途中切到别的栏目再切回来，同一条 cue
      要能立刻正常拖动（不该有一次「拖了没反应」）。
- [ ] **框只扫过字幕行的留白**（块上下各 4pt）：不许选中任何 cue；
      擦到块本体就要选中。形状行同理（上下各 3pt）。
- [ ] **切工程**：选中 cue 后新建/打开另一个工程，新工程不许带着拖框开场。
- [ ] **删/换字幕轨**：选中 cue 后移除字幕或外挂一份新 .srt，拖框当场消失。
