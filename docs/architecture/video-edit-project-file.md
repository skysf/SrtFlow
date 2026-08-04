# 剪辑工程文件（.srtflowproj）与素材重链接

> 2026-08-03 定稿。**改工程存盘、素材路径、自动保存相关的代码前必读。**
>
> 相关：[still-image-pipeline](../bugfixes/)、`docs/testing/gui-smoke-testing.md`

## 一、为什么不做 App 内的文件夹管理

最初的想法是「Edit Video 默认进一个 Finder 式的项目界面，文件夹里建工程」。
否掉了，理由是：

1. **等于自建第二套 Finder。** 重命名、拖拽移动、多选、删除到废纸篓、搜索、
   排序、右键菜单、撤销都得自己实现，几千行，且永远不如 Finder。
2. **两套心智模型会打架。** App 内的层级如果只是数据库里的记录，用户在 Finder
   里移动或删掉工程文件后库就烂了（DaVinci 项目管理器的经典痛点）；如果它对应
   真实目录，那就是个残废版 Finder。

**定下来的形态**：工程就是一个普通文件，分文件夹/改名/搜索/备份**全部交给
Finder**。App 只负责「快速回到最近那几条」。

- 「最近工程」直接读系统那份列表（`NSDocumentController.recentDocumentURLs`），
  跟 Dock 图标右键看到的是同一份，**不要**自己再存一套。
- 起始页（`VideoEditStartScreen`）只有：拖放提示 + Add Media + Open Project +
  最近工程网格。**不要**往这里加文件夹、标签、重命名之类的库管理功能。

## 二、其余几条产品决策（用户拍板，推翻要先问）

| 决策 | 结论 |
| --- | --- |
| 工程范围 | 只属于 Edit Video。Burn In 是独立的一栏，日后是否并入再说 |
| 窗口形态 | **单窗口栏内切工程**，同时只开一个。刻意不用 `NSDocument`/`DocumentGroup` —— 那套要求一个工程一个窗口，跟「一个主窗口 + 侧边栏切工具」的结构对不上 |
| 保存方式 | **自动保存**：改动后 2 秒防抖写盘，⌘S 只是「立刻 flush」，关窗/切栏目不弹「要保存吗」 |
| 素材归属 | **只存引用，不拷贝**。工程文件几十 KB |
| 未命名工程 | 拖素材进来就能开工，不强制先建工程；`documentURL == nil` 时**不自动落盘**，等第一次 ⌘S / Save As |

## 三、文件格式

`.srtflowproj` 是一份 pretty-printed JSON（UTI `com.srtflow.project`，在
`packaging/Info.plist` 里声明了 `UTExportedTypeDeclarations` +
`CFBundleDocumentTypes`，双击能回到 SrtFlow）。

```
{ formatVersion, savedAt, timeline: TimelineState, media: [MediaRecord] }
```

### 宽容解码是硬约束

`TimelineState` / `EditClip` / `EditLane` / `ShapeAnnotation` / `MediaInfo` 的
`Codable` **全部手写**，每个字段走 `decodeIfPresent` + 默认值；四个字符串枚举走
`LenientCodableEnum`，读到不认识的值退回兜底项。

> **加字段时照这个写法加**（给默认值，不要依赖合成的 `Codable`）。Swift 合成的
> 解码器碰到缺失的键会让**整份工程打不开** —— 这是文档格式最典型的坑。
>
> **同时必须把 `currentFormatVersion` +1**（只要旧版会把这个字段静默丢掉）。
> 宽容解码只保证「新版能读旧文件」；「旧版拿到新文件不毁数据」只有版本闸门
> 能拦 —— 旧版拒开，胜过打开后在下一次自动保存时把新字段悄悄删光。
> 见 [2026-08-04-transform-review](../bugfixes/2026-08-04-transform-review.md)。

### 存盘必须带上一次的定位表

`VideoEditProjectIO.save(_:to:knownRecords:)` 的 `knownRecords` **不是可选的优化，
是正确性要求**。素材此刻不可达时（工程开着的时候被移走、外接盘拔了），
`bookmarkData()` 会失败返回 nil；不拿旧记录兜底就会把**还能定位到它的那份书签
覆盖成 nil**。更糟的是：随便哪个素材自动找回触发一次回存，就会连带抹掉其他仍在
丢失状态的素材的全部线索。

调用方（`VideoEditProject.saveNow`）要把返回的新表存回 `mediaRecords`，形成
读 → 存 → 读的闭环。手动重链接之后还要把表里的**键**从旧路径换成新路径。

### 版本校验

`formatVersion` 比当前大的工程**必须拒绝打开**。硬打开的话，这版不认识的字段会在
下一次自动保存时被静静删掉 —— 等于毁掉用户在新版里做的活。

### 不进工程文件的东西

- `EditClip.needsStillConversion` —— 导入过程中的临时状态。
- **图片段生成出来的静帧视频**。图片走 `StillImageClipFactory` 转成静帧循环视频
  后才上时间线，那个 mp4 在 `~/Library/Caches` 里，随时可能被系统清掉。所以
  工程只登记 `stillImageURL`（原图），打开时缓存命中就直接接上，没命中就报进
  `LoadResult.stillsToRegenerate` 由 `regenerateStills` 重转，用户无感。
  **不要把 `sourceURL` 当成图片段的真身。**

  这条链上有三个坑，都踩过：

  1. **重转前必须 `awaitVideoEngine()` 等 ffmpeg，不能直接取 `runtime`。**
     冷启动双击工程时，`application(_:open:)` 跑在窗口出现之前，而
     `MediaToolchain.resolveIfNeeded()` 要等 `onAppear` 才被调到 —— 那一刻
     `runtime` **必然**是 nil。直接 return 的话图片段永久停在待转换。
  2. **手动重链接图片之后要再跑一次 `refreshStillClips`。** 重链接只换了
     `stillImageURL`，`sourceURL` 还指着那份多半已经不存在的旧缓存。
  3. **导出遇到 `needsStillConversion` 必须报错，不能过滤掉。**
     `VideoEditExporter.plan` 以前直接把这些段滤掉，导出会「成功」但用户的图片
     凭空消失且毫无提示。

## 四、素材重链接：四层线索

`VideoEditProjectIO.resolve` 按从快到慢的顺序试，命中即返回：

| 层 | 手段 | 覆盖的情况 |
| --- | --- | --- |
| 1 | 原路径 `fileExists` | 素材没动过 —— 绝大多数情况在这里就返回了 |
| 2 | `URL.bookmarkData()` | **改名、移到同一个盘的任何角落、又改名又移动**。书签记的是 inode + 卷标识而不是路径，这是 macOS 自带的能力 |
| 3 | 相对工程文件的路径 | 工程 + 素材**整个文件夹一起搬走或拷到别的机器**（新 inode，书签失效） |
| 4 | 按文件名 + 大小搜索 | 外接盘换挂载点、从备份恢复。搜索范围：工程目录 + 本次已找到素材的目录 |

四层都没中才进 `missingMedia`，界面上是 `MissingMediaBar`（橙条 + Relink 菜单）。
**素材丢了时间线不能丢** —— 剪辑照样留在轨上，重新链接后接着剪。

几条不能改的细节：

- **相对路径最多往上走三层**（`MediaRecord.relativePath`）。再远就不像「一起
  搬走」的关系，容易误配到别的文件。
- **同名搜索必须验大小**，深度限 3 层，并且 4000 条目的预算是**整次载入共用的
  全局预算**（`searchEntryBudget`，按 `inout` 传下去）。每个素材各给一份的话，
  丢 20 个素材 × 5 个已知目录 = 最坏 40 万次 stat，打开工程会卡死。
- **载入要放在后台线程**（`openProject` 里的 `Task.detached`）。它要遍历素材、
  可能还要翻目录，占着主线程就是转圈。
- **手动重链接要按目录批量匹配**：用户指认一个文件后，同目录下其他丢失素材按
  文件名自动配上（`promptRelink`）。素材通常整批一起搬，别让人点十遍。
- **靠 2/3/4 层找回来的要立刻回存一次**（`LoadResult.didRelink` → `saveNow`），
  否则下次打开又要重走慢路径。

## 五、脏标记与自动保存

- **`state` 的 `didSet` 是唯一的脏标记入口**。所有时间线写入（`perform` /
  `liveApply` / `applySnapshot`）最终都是给 `state` 赋值，挂这一个点就够了；
  别在各个操作里分别标脏。
- 不算用户改动的写入走 `replaceStateForDocument`（整体换）或
  `applyDocumentRepair`（局部修补），它们用 `isLoadingDocument` 把脏标记压住 ——
  打开工程、补静帧、重链接素材都属于这一类。
- **切工程前必须走 `closeCurrentDocument`**：作废工程代号 + 停播放 +
  `clock.detach()` + `cancelLiveEdit()` + 清选择 + 清定位表 + **清撤销栈**。
  漏掉撤销栈的话，⌘Z 能把上一条工程的内容撤回到当前工程里。
- flush 的三个时机：切走 Edit Video 栏（`onDisappear`）、⌘S、退出 App
  （`applicationWillTerminate`）。自动保存有 2 秒防抖，正好卡在那两秒里按 ⌘Q
  会丢改动。

### 切工程必须是事务性的

**`flushAutosave()` / `saveNow()` 的返回值必须被在意。** 磁盘满、权限变了、外接盘
被拔掉的时候保存是失败的；以前无条件 flush 完就关，未保存的编辑直接没了。

固定顺序（`prepareToCloseDocument` → `closeCurrentDocument` → 应用新内容）：

1. **`openProject` 要先把目标读出来验明正身，再动手里这条。** 反过来的话，目标
   文件损坏时当前工程已经被关掉了 —— 画面还在，但 `documentURL`、撤销栈、脏标记
   全没了，后面的编辑再也不会自动保存。
2. `prepareToCloseDocument()` 返回 false 就**原地不动**，别调 `closeCurrentDocument`
   （它会把保存失败的 notice 一起清掉）。
3. 从没存过、又有内容的未命名工程要弹 Save…/Discard/Cancel。自动保存的语义只覆盖
   已经有位置的工程，没位置的直接扔就是数据丢失。
4. **打开的就是当前工程时，只 flush，不载入。** 「先读后关」的顺序在这个特例上
   会反噬：读到磁盘旧状态 → flush 写下新状态 → 又拿旧状态盖回内存并标成干净，
   下一次编辑把新状态从磁盘上也抹掉。Open Recent 里永远有当前工程，这条路是
   真实可点的。
5. **每个 await（含模态框的嵌套 runloop）之后要验 `openRequestToken`。** 连点
   两个最近工程时，慢的那个后回来会把先打开的顶掉。
6. **Save As 的新身份只有写盘成功才作数**：先暂存旧 `documentURL`/书签，
   `saveNow()` 失败就整个回滚，否则工程卡在一个写不进去的 URL 上。
7. **退出必须走 `applicationShouldTerminate`**，失败或用户点取消就
   `.terminateCancel`。`willTerminate` 那一步已经拦不住退出，写盘失败只能眼睁睁
   丢数据。

### 后台导入要带工程代号

导入（探测时长、图片转静帧）是脱手的 Task，工程切走之后它们才回来。
`closeCurrentDocument` 会 `invalidateDocumentGeneration()`，**每个 await 之后、
每次写 `state` 之前都要 `isCurrentGeneration(generation)` 复核**，否则素材会被
追加进新工程，或者平白把新工程标脏。新增任何后台导入都要走 `trackImportTask`。

两个容易搞错的细节：

- **代号必须在创建 Task 之前抓，作为参数传进任务体。** Task 创建后未必立刻跑；
  等它跑起来时工程可能已经切了，那时在体内读 `documentGeneration` 读到的是
  **新**工程的代号，守卫形同虚设。任务入口再补一道 `Task.isCancelled`。
- **失败分支写 `notice` 之前也要验代号**，否则旧工程素材的报错会写到新工程脸上。

### 图片段的身份要在复制路径上跟着走

`stillImageURL`（和 `needsStillConversion`）是图片段的真身标记。**任何从旧段
构造新段的代码**（分割 `split`、将来可能的复制/粘贴）都必须把这两个字段带上；
丢了的话新段会把静帧缓存 mp4 当真实素材写进工程，缓存一清这段就无法重建。

## 六、工程文件自己也会被搬走

`documentURL` 是普通路径 URL，用户在访达里把**正开着的**工程改名或挪走之后，
按旧路径保存会在旧位置重新造一个旧名字的文件 —— 用户以为在编辑的那份反而再也
不更新。所以打开/保存时给工程文件本身也存一份书签（`documentBookmark`），
`saveNow` 发现旧路径不在了就用它把 `documentURL` 跟过去。

## 七、回归清单

改上述任何一块后，至少跑：

1. `scripts/check-project-file.sh` —— 存取往返、四层重链接、丢失上报、宽容解码、
   **书签保全**、版本校验、重链接后补静帧，42 项。
   **加了新字段要往 `checks/ProjectFile/main.swift` 里补一条。**
2. 真实窗口冒烟（流程见 `docs/testing/gui-smoke-testing.md`）：
   - 双击 `.srtflowproj` → 落到 Edit Video 并载入素材、画布比例正确
   - 空工程 → 起始页显示最近工程，重启 App 后还在
   - 把素材**改名** → 重开工程 → 应当**无感自动找回**（书签），且工程被回存
   - 把素材**删掉** → 重开工程 → 橙条报丢失、剪辑仍在轨上
   - **冷启动**双击一个含图片段、且静帧缓存不存在的工程 → 图片段应当自动转好
     并出现在预览里（验 `awaitVideoEngine`）
   - 未命名工程里加一段素材 → File ▸ New Project → 应弹 Save…/Discard/Cancel，
     点 Cancel 后剪辑还在；⌘Q 也应弹同一个框，Cancel 能取消退出
