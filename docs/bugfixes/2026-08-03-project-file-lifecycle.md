# 2026-08-03 工程文件生命周期的一批数据丢失路径（两轮 review，11 处）

## 症状

`.srtflowproj` 工程系统首版落地后，两轮代码 review 各查出一批「代码能跑、
自检全绿，但特定时序下丢数据」的问题。用户可见的最终形态都是同一类：

- 素材的定位信息（书签）莫名消失，本来能自动找回的素材变成永久丢失；
- 切工程 / 退出 App 时未保存的编辑无声消失；
- 图片段从导出的成片里凭空消失，导出却报「成功」；
- 从 Open Recent 重开当前工程后，最近两秒的编辑被磁盘上的旧状态顶掉。

## 根因

共性根因：**首版只写了主干路径，生命周期边界（保存失败、任务竞态、重复打开、
退出、分割复制）上的每一条都默认「上一步总是成功/有序」**。具体 11 处：

1. 每次保存都按当前 URL 重造全部 `MediaRecord`。素材此刻不可达时
   `bookmarkData()` 返回 nil，把**还有效**的旧书签覆盖掉；任何一次自动保存
   都会连带抹掉其他丢失素材的线索。
2. 切工程无条件 `flushAutosave()` 后直接关，不看成败。写盘失败（磁盘满、
   外接盘被拔）时未保存编辑直接丢。
3. 后台导入（探测/转静帧）不带工程代号，切工程后旧任务回来把素材塞进新工程。
   **第二轮追打**：代号在 Task 体内才读也不行 —— Task 创建后未必立刻跑，
   跑起来时读到的已经是新工程的代号，守卫形同虚设。
4. 静帧恢复在 ffmpeg 未就绪时直接 return，之后无重试。冷启动双击工程时
   `runtime` **必然**是 nil（解析要等 `onAppear`），图片段永久停在待转换；
   而导出计划把待转换段**静默过滤**，图片消失且无提示。
5. 正开着的工程在访达里被改名/移动后，保存写回旧路径造出旧名字的新文件。
6. `formatVersion` 从未校验，旧版打开未来工程后自动保存会删掉不认识的字段。
7. 同名搜索的 4000 条目预算是每次 `search()` 各一份，最坏
   丢失数 × 目录数 × 4000 次 stat，且载入同步占主线程。
8. 「先读目标再关当前」的打开顺序，在**目标就是当前工程**时反噬：读旧状态 →
   flush 新状态 → 旧状态盖回内存标干净 → 下次编辑把新状态从磁盘也抹掉。
9. 退出走 `applicationWillTerminate`，那时已拦不住退出，写盘失败照样退。
10. 分割图片段时右半段没带 `stillImageURL`/`needsStillConversion`，把静帧
    缓存 mp4 当真实素材写进工程，缓存一清就无法重建。
11. Save As 先换 `documentURL` 再写盘，写失败后工程卡在写不进去的新 URL 上。

## 修复

全部约束的权威版在
[docs/architecture/video-edit-project-file.md](../architecture/video-edit-project-file.md)，
这里只列对应入口：

| # | 修法 | 入口 |
| --- | --- | --- |
| 1 | `save(_:to:knownRecords:)` 拿旧记录兜底，书签只能补不能抹成 nil | `VideoEditProjectFile.swift` `MediaRecord.init(url:projectDirectory:previous:)` |
| 2 | `flushAutosave`/`saveNow` 返回 Bool；`prepareToCloseDocument` 失败即中止切换；未命名有内容弹 Save/Discard/Cancel | `VideoEditProjectDocument.swift` |
| 3 | 代号在 `addMedia` **创建 Task 前**抓、作参数传入；任务入口验 `Task.isCancelled`；失败分支写 notice 前也验代号 | `VideoEditProject.swift` `addVideos/addAudios/addImages` |
| 4 | `awaitVideoEngine()` 等引擎就绪；重链接后重跑 `refreshStillClips`；导出遇待转换段**抛错**（只看可见轨） | `VideoEditProjectDocument.swift`、`VideoEditExporter.plan` |
| 5 | 工程文件自身存 `documentBookmark`，`saveNow` 发现旧路径没了就跟过去 | `VideoEditProjectDocument.swift` |
| 6 | `formatVersion > current` 拒绝打开 | `VideoEditProjectIO.load` |
| 7 | 4000 条目改为整次载入共用的 `inout` 预算；载入挪进 `Task.detached` | `VideoEditProjectIO` |
| 8 | 目标 == 当前工程时只 flush 不载入 | `openProject(at:)` 开头 |
| 9 | 改走 `applicationShouldTerminate`，失败/取消返回 `.terminateCancel` | `SrtFlowApp.swift` |
| 10 | 分割右半段带上 `stillImageURL` + `needsStillConversion` | `VideoEditProject.split` |
| 11 | Save As 暂存旧身份，写失败整体回滚 | `saveDocumentAs` |

另修 #5（乱序打开）：`openRequestToken` 流水号，每个 await（含模态框嵌套
runloop）之后复核，过期结果直接扔。

## 验证

- `scripts/check-project-file.sh` 42 项，含专门的回归项：书签保全（带对照组
  证明不修会丢）、版本拒绝、重链接后补静帧。
- 真机冒烟（流程按 docs/testing/）：冷启动双击含未转换图片段的工程 → 静帧
  自动转好进预览（修前必现卡死在 pending）；未命名工程点 New Project → 弹
  三按钮框，Cancel 后剪辑原封不动。
- 用不可写目标模拟保存失败，确认 `VideoEditProjectIO.save` 抛错、Bool 链路
  有效。
- 未覆盖：磁盘满等真实写盘失败下的整条 GUI 链路（退出取消、Save As 回滚）
  只验了逻辑，没造出真环境。

## 教训 / 防回归

- **「能跑通主干」和「不丢数据」是两个完成度**。凡是涉及用户数据的状态机，
  review 要专门过一遍：每个失败分支丢什么、每个 await 前后世界变了没有、
  每条「从旧对象造新对象」的路径带没带全字段。
- 竞态守卫的取值时机和守卫本身同等重要（#3：代号晚读一步就整个失效）。
- 「静默过滤」在导出这类终点操作里等于吞数据，宁可报错拦下。
- 长期约束已全部落到
  [docs/architecture/video-edit-project-file.md](../architecture/video-edit-project-file.md)，
  改工程存盘/素材路径/自动保存/导入前**必读那份**，本案例只记事故本身。
