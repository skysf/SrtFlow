# 2026-08-08 运行中素材被改名/挪走：预览黑屏零提示，改个变速才暴露

## 症状

用户给主轨一段录屏改了 1.4x 变速，预览窗口从此黑屏；轨道上的缩略图却一切正常，
于是第一反应是「变速把视频弄坏了」。实际触发条件与变速无关：工程开着的时候，
素材文件在访达里被挪出了原目录、还改了名。改变速只是**第一个触发预览重建**的
编辑——重建按旧路径加载素材失败，那段就黑了。

另一半症状：就算文件只是改名（还能靠书签找回来），界面上的剪辑块也一直显示
旧文件名，看不出任何变化。

## 根因

1. **四层重链接线索只在「打开工程」时跑一遍**（`VideoEditProjectIO.load`）。
   运行中没有任何机制重核对素材位置，`missingMedia` 不更新，Relink 橙条永远
   不会出现。
2. **预览重建对加载失败的素材只能静默跳过**（`VideoEditCompositionBuilder.build`
   里 `loadTracks` 失败就 `continue`）。这是合理的兜底，但上游没人把「跳过了」
   这件事告诉用户 —— 结果就是黑屏零提示。
3. **轨道缩略图是缓存**，文件消失后照常显示旧画面；剪辑名 `EditClip.name` 虽是
   从 `sourceURL` 现算的，但引用没人更新，名字自然也不变。三件事叠加，用户
   看到的现场把矛头齐齐指向「变速」。

## 修复

把打开工程用的那套四层线索抽成运行中可调的纯函数，在两个时机重跑：

- `VideoEditProjectIO.relocateMedia(urls:records:projectDirectory:)`
  （`VideoEditProjectFile.swift`）——与 `load` 完全同一套 `resolve` 四层线索；
  顺带把 `resolve` 的 `projectDirectory` 放宽成可选（未命名工程没有工程目录，
  书签这层照样要能用）。
- `VideoEditProject.revalidateMediaLocations()`（`VideoEditProjectDocument.swift`）
  —— 单飞 + 后台跑 `relocateMedia`，回主线程后**只对此刻仍被时间线引用的路径**
  动手：跟得上的走 `applyDocumentRepair` 改引用（剪辑块名字立刻跟新）、按
  `promptRelink` 同一套账更新 `mediaRecords`、立刻回存（同 `didRelink`）；
  跟不上的写进 `missingMedia` 亮出橙条；文件回到原位的自动消条。
- 触发点一：`NSApplication.didBecomeActiveNotification`（`VideoEditProject.init`）
  ——去访达动文件必然让 App 失焦，切回来的瞬间就是重核对的最佳时机。
- 触发点二：`scheduleRebuild()` 入口 —— 兜住「终端里改名」这类不经过失焦的
  路径，保证黑屏出现的那次重建旁边一定跟着一次核对；核对若改了引用会再触发
  一次重建，第二轮全部原地命中即收敛，不会循环。

## 验证

- `scripts/check-project-file.sh`：103 项全过。新增第 16 组用例覆盖
  `relocateMedia` 的四种情形：改名+移动靠书签跟上、未命名工程（无工程目录）
  书签照样生效、文件真删了老实报丢失、原地未动零动静。
- 真实窗口冒烟（SrtFlowDev.app 流程，见 `docs/testing/gui-smoke-testing.md`）
  三幕连做：
  1. 开着工程把素材 `clipA.mp4` 改名并挪去别的目录 → 切回 App：剪辑块标题
     变成 `clipA-rena…`，预览不黑，`.srtflowproj` 已自动回存新路径；
  2. 把文件删掉 → 切回 App：橙条「“clipA-renamed.mp4” could not be found.」+
     Relink 菜单当场出现，剪辑仍在轨上；
  3. 在原路径放回同名文件 → 切回 App：橙条自动消失。

## 教训 / 防回归

- **「打开时校验过」不等于「一直有效」**。引用外部资源的长期会话（工程、
  录制、缓存）都需要一个运行中的重核对时机；`didBecomeActive` 是「用户刚在
  别处动过文件系统」的天然信号，成本只是每素材一次 `fileExists`。
- **静默跳过必须有人在上游补提示**。builder 跳过加载失败的段是对的（它没有
  UI 责任），但每一个「跳过」都要有一条对应的用户可见路径，否则就是这次的
  黑屏零提示。与字幕生成评审的「覆盖类账本宁缺毋假」同源。
- **现场证据会说谎**：缩略图是缓存、选中框画的是元数据，都不代表素材还在。
  排查「某段黑屏」先查 `sourceURL` 在不在磁盘上，再怀疑滤镜/变速管线。
- 长期约束已并入 [video-edit-project-file](../architecture/video-edit-project-file.md)
  第四节：运行中重核对与打开工程必须**共用同一套 `resolve` 线索**，两边行为
  分叉就会出现「重开能找回、运行中却报丢失」的割裂。
