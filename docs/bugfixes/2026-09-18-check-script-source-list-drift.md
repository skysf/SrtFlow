# 2026-09-18 自检脚本的源文件清单漏掉新依赖：八项检查在 CI 齐红

## 症状

PR #38（轨道头整行点选 + 单段隐藏）本地跑过的检查全绿，推上去后 `check-all` 红了
**八项**：freeze-frame、timeline-snap、screen-recording-writer、export-frame-rate、
audio-fade、video-fade、clip-animation、text-render。

日志里全是同一条编译错误，跟这些检查各自要守的东西一点关系都没有：

```
Sources/SrtFlow/VideoEditModels.swift:845:22: error: cannot find 'ClipVisibility' in scope
```

## 根因

被测代码在 `SrtFlow` 这个 app target 里，而 SwiftPM 不允许两个 target 共用同一批
源文件 —— 所以每个自检脚本都**自己手抄一份源文件清单**，用 `xcrun swiftc` 编成
独立二进制（见 `scripts/check-project-file.sh` 开头的说明）。

这次给 `VideoEditModels.selectionForExport` 加了一处 `ClipVisibility.visible(…)`
调用，新文件 `VideoEditClipVisibility.swift` 只加进了**改动直接相关的两个脚本**
（check-project-file、check-preview-composition）。另外八个脚本照样编
`VideoEditModels.swift`，却没有它的定义，当场编不过。

放大它的是**本地只跑相关单项**这条节奏：相关的两项确实绿了，而「模型多一个依赖
会波及所有编模型的脚本」这件事，只跑两项永远看不见。节奏本身没错（全量留给
CI），缺的是一条能在本地一秒钟说清楚的守卫。

## 修复

1. 把 `Sources/SrtFlow/VideoEditClipVisibility.swift` 补进全部 10 个编
   `VideoEditModels.swift` 的脚本清单（紧跟模型那一行，成对出现最不容易再漏）。
2. 新增扫描守卫 `checks/check-script-source-lists.sh`，并接进
   `scripts/check-all.sh`：**凡是编模型的脚本，模型引用到的同伴文件必须都在清单
   里**。同伴关系**从源码现算**（模型代码里引用了哪些定义在别的
   `Sources/SrtFlow` 文件里的顶层类型），不写死表 —— 写死的表会腐烂，而下次给
   模型添依赖时，这条守卫自己就知道该要哪个文件。
3. 判据只认 `xcrun swiftc` 续行块里的源文件行：扫描守卫的参数行
   （`require "…" Sources/…swift '正则'`）只是提到路径，当成编译清单会误红。

## 验证

- `bash checks/check-script-source-lists.sh` → `10 个脚本都带齐了模型的 6 个同伴
  文件`。
- **反向验证**：从 `scripts/check-text-render.sh`（以及另一次从
  `check-freeze-frame.sh`）删掉那一行 → 守卫立刻点名该脚本缺哪个文件；补回即绿。
- 把 10 份清单逐个 `swiftc -typecheck`（不跑重活，只验编译）：CI 里红的八项全部
  通过。
- 回归面：`scripts/check-project-file.sh`（463 项）、
  `scripts/check-preview-composition.sh`（194 项）本地复跑仍绿；其余单项与全量
  `check-all` 交给 CI。

## 教训 / 防回归

- **手抄的清单一定会漂。** 加一个被 `VideoEditModels.swift`（或其他枢纽文件）引用
  的新文件时，改的不是一个脚本，是**所有**编它的脚本。
- 「只跑相关单项」的前提是：跨脚本的连带影响得有守卫兜着。这次补的守卫就是那层
  兜底 —— 它几毫秒跑完，属于本地随手可跑的那一类。
- 同类教训见 [CI 首跑与吞错](2026-08-08-ci-first-run-sdk-and-swallowed-errors.md)：
  编译失败必须在日志里看得见，别让它被 `>/dev/null` 吞掉。
