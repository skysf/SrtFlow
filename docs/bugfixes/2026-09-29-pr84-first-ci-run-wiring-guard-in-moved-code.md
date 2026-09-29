# 2026-09-29 搬走调色代码之后，一条接线守卫还在旧文件里找：本机全绿、只在 CI 上红

## 症状

`feat/blur-mosaic-block` 开 PR（#84，盖一块 = 模糊 / 马赛克）后第一次跑全量 CI，5 组里第 4 组红，其余四组绿：

```
✗ 接线守卫：导出的调色读 renderedFilters（在 Sources/SrtFlow/VideoEditExportGraph.swift 里找不到 /state\.renderedFilters\.filter/）
接线守卫失败
✗ project-file（工程存盘/重链接） 失败
```

本机：完整 `swift build` 和 `checks/*.sh` 的 23 个扫描守卫全绿。

## 根因

1. **搬了代码，守卫还指着旧地方。** 给盖一块腾地方，把导出图里调色那一段原样搬进了新文件 `VideoEditGradeExport.swift`
   （`VideoEditExportGraph.swift` 在行数基线里、只许降）。`scripts/check-project-file.sh` 尾部有一条钉着「导出的调色读
   `renderedFilters`」的接线守卫，路径写死在旧文件上。
2. **这是 2026-09-25 [PR #71 首跑 CI](2026-09-25-pr71-first-ci-run.md) 同一个坑的第二次。** 那份案例的教训写的就是
   「改接线之后，按旧名字把 `scripts/` 和 `checks/` 全 grep 一遍」—— 写在案例里，这次没照做。
   **靠「记得去 grep」的规矩会被忘。** 更深一层的原因是位置：这批接线守卫接在 `check-project-file.sh` 的**末尾**，前面隔着
   一次 25 秒的编译，而本地的工作方式是「只跑秒级的扫描守卫、编译类的检查交给 CI」—— 这一段永远轮不到本地跑，
   于是每一次搬代码都要等 CI 才知道。

## 修复

1. 那条守卫指到新文件 `VideoEditGradeExport.swift`。
2. 补三条盖一块的接线守卫（和形状 / 文字 / 滤镜那几条同形）：预览的第二层（`CoverStack`）、导出的滤镜图、AI 的「看」
   （`AIFrameComposer`）都读 `renderedCovers`，藏起来的不盖。
3. **结构上：把接线守卫这一段（344 行）从 `check-project-file.sh` 拆成 `checks/project-file-wiring.sh`**，进 `check-all.sh`
   第 1 组，和其它扫描守卫一样秒级、不编译、本地一起跑；`check-project-file.sh` 只剩「编译 + 跑断言」（471 → 145 行）。
   逐条守卫原样搬，没有改任何一条的判据。
4. 顺手：盖一块那批文件里几处把日期写成了「2026-09-30」（当天是 09-29），改回。

## 验证

- 本机：`checks/project-file-wiring.sh` `✓ 接线守卫通过`（拆开前后逐条一样）；`scripts/check-all.sh` 第 1 组的扫描守卫全绿。
- **反向验证**：分别把 ① 预览读 `renderedCovers` 的那处 ② 导出图里读 `renderedCovers` 的那处 ③ AI 的「看」里读的那处
  ④ 导出的调色读 `renderedFilters` 的那处改坏，守卫**各红一条**（每次恰好一条 ✗），恢复后全绿。
- 推送前按旧名字把 `scripts/`、`checks/` 全 grep 了一遍（`renderedFilters` 只有这一条还指着旧文件）；
  其它脚本里的「扫描守卫」要么放在编译之前（`check-freeze-frame.sh` 的准入条件），要么本来就在 `checks/` 下。
- CI 在同一个 PR 上重跑全量。

## 教训 / 防回归

- **同一个教训写过一次还撞第二次，说明「写进案例」不够，要把它变成机制。** 能在本地秒级跑的检查就不要放在编译后面：
  新写「这段代码有没有被调用」这类接线守卫，放进 `checks/` 下成一个独立的扫描守卫，而不是接在某个要编译的脚本末尾。
- **搬代码（不改行为）也算改接线。** 搬完先跑 `checks/*.sh`（含 `project-file-wiring.sh`），再推。
- 「守卫路径写死在文件上」是这类守卫的固有代价：文件搬家就要跟着改。别为此把守卫写成「全仓库 grep」—— 那会让
  「藏在别的文件里的同名字符串」把红的守卫捂成绿的。
