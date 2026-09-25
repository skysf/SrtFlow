# 2026-09-24 改得勤就隔一会儿卡一下：自动保存每次都重建全部素材的书签

## 症状

在 57 个素材的工程里连着改（拖、裁、调音量），每隔一会儿主线程顿一下，和正在做的动作没有
关系。查 [时间线卡顿](2026-09-24-timeline-blocks-observe-whole-project.md) 时用 `sample`
抓点选那一段的主线程栈，`VideoEditProject.scheduleAutosave` → `VideoEditProjectIO.save`
→ `MediaRecord.init` 占了 60 个样本（约 60 ms），几乎全在 `url.bookmarkData(...)` 里。

## 根因

`MediaRecord.init(url:projectDirectory:previous:)` 每次都现建一份系统书签。自动保存是
「每改一下、停 2 秒就存一次」，一次存盘要给每个素材都建一遍：建书签要走 LaunchServices
查隔离属性，57 个素材约 55 ms，而且在主线程上。素材没换过，重建出来的书签和上一份一样。

## 修复

新文件 `Sources/SrtFlow/VideoEditMediaBookmarkCache.swift`（`MediaBookmarkCache`）：同一个
文件这次会话里建过书签就用旧的，`MediaRecord.init` 改走它。

**什么时候必须重建**：书签记的是 inode + 卷，所以只要这个路径上还是同一个 inode，旧书签就
还对；路径上换成了别的文件（重新导出盖掉了、删了又放回一个同名的）就得重建，不然以后这个
文件被挪走时，书签会把工程指回旧的那个（比如废纸篓里那份）。所以缓存按「路径 + inode + 卷」
认，变了一样就重建。文件不在（读不到 inode）返回 nil，交给调用方沿用上次存的（`MediaRecord`
原有的「旧记录只能补，不能覆盖成 nil」）。

## 验证

`scripts/check-project-file.sh` 第 30 组（`checks/ProjectFile/BookmarkCache.swift`，由新的
`SplitGroups.swift` 统一调用 —— `main.swift` 是登记过的老超标文件，只许降）：

1. 同一个文件连存两次，书签只建一次、两次是同一份；
2. 写一个新文件再 `rename` 盖过去（路径不变、inode 变）：必须重建，且不能还是旧文件那份；
3. 文件删掉：缓存返回 nil，`MediaRecord` 沿用上次存的书签。

反向验证：把「命中缓存」那个分支改成 `if false`（永远重建）→ 第 1 条报 `got 2, expected 1`、
第 2 条报 `got 3, expected 2`；恢复后 700 条全过。

## 教训 / 防回归

- **自动保存的每一步都要按「每 2 秒来一次」的频率算成本。** 存盘里任何 O(素材数) 的系统调用
  都会变成周期性的卡顿，而且栈上看不出和用户动作的关系。
- 缓存文件相关的东西要说清「什么时候失效」并且用 inode 判，不能只按路径：同名换文件在这个
  仓库是常态（重新导出）。
