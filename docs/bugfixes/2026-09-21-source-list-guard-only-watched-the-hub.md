# 源文件清单守卫只盯着枢纽文件，另外两类漏项它一个都看不见

> 2026-09-21。滤镜第一刀（PR #53）本地全绿，CI 六项当场编不过。
> 相关：[上一次同类事故](2026-09-18-check-script-source-list-drift.md)、
> [滤镜](../architecture/filters.md)。

## 症状

`feat/filters-slice1` 本地跑过 `check-project-file` / `check-preview-composition` /
`check-filters` / `check-localization-coverage` 和三条接线扫描，全绿；
`checks/check-script-source-lists.sh` 也绿。推上去之后 CI 的 `check-all` 红了六项：

```
失败的： player-clock export-frame-rate audio-fade video-fade clip-animation text-render
通过 20 项，失败 6 项
```

全是同一类编译错误：

```
Sources/SrtFlow/VideoEditExportGraph.swift:575:21: error: cannot find 'FilterLUT' in scope
Sources/SrtFlow/VideoPreviewView.swift:176:22: error: cannot find type 'FilterStack' in scope
```

## 根因

每个自检脚本都自己列一份 `xcrun swiftc` 源文件清单（被测代码在 SrtFlow 这个 app
target 里，SwiftPM 不允许两个 target 共用同一批源文件）。清单是手抄的，就会漂 ——
这正是 2026-09-18 那次事故之后写下 `checks/check-script-source-lists.sh` 的理由。

但那条守卫只算了**一个**文件的同伴：

```bash
HUB="Sources/SrtFlow/VideoEditModels.swift"
```

于是它看得见「`VideoEditModels.swift` 用到了新的 `FilterClip`」，看不见另外两类：

1. **`VideoEditExportGraph.swift` 用到了新的 `FilterLUT`** —— 六个脚本里有五个编
   导出图，全都缺这个文件。
2. **`VideoPreviewView.swift` 用到了新的 `FilterStack`** —— `check-player-clock.sh`
   只编这一个文件，缺的是整条依赖链。

守卫自己的说明里写着「同伴关系**从源码现算**，不写死表」，读起来像是「加依赖它自己
就知道」。实际只对枢纽文件成立 —— 这层限制没写在文档里，所以本地绿的时候没人怀疑。

## 修复

**一、把守卫扩到清单里的每一个文件**（`checks/check-script-source-lists.sh` 第 4 节）：
对每一份 swiftc 清单，清单里的每个 `Sources/SrtFlow/*.swift` 引用到的顶层类型，
它们所在的文件也必须在同一份清单里。判据和原来那节一模一样，只是作用范围从
「枢纽文件」变成「清单里的所有文件」。

实现上换了算法：原来是「逐个类型去 grep 每个文件」，O(类型 × 文件 × 脚本)，扩到
全清单之后实测跑不完（150 个类型 × 150 个文件 × 20 个脚本）。改成先把文件里出现
的大写标识符抽一次，再和类型表 `join`，结果按文件缓存 —— 同一个文件会被十几份清单
问到。全量 30s。

**二、把播放器视图从 `VideoPreviewView.swift` 拆出去**（新文件
`PlayerViewRepresentable.swift`）。那个文件原本混着两件事：`PlayerClock`（纯模型，
链式 seek 和悬停 peek 的状态机）和 `PlayerViewRepresentable`（视图）。
`check-player-clock.sh` 只想要前者，却因为同在一个文件里被迫连带编进视图的依赖；
这一刀给视图加了「此刻的调色」之后，那条依赖一路牵到 `TimelineState`，小检查当场
编不动。拆开之后那份清单回到只有一个文件，比事故前还干净。

**三、补齐七个脚本的清单**（六个加 `VideoEditFilterLUT.swift`，外加之前已经补过
`VideoEditFilterModels.swift` 的那十个）。

## 验证

反向验证：从 `scripts/check-video-fade.sh` 的清单里临时删掉
`VideoEditFilterLUT.swift`，守卫当场变红并指名道姓：

```
✗ scripts/check-video-fade.sh 的源文件清单缺 Sources/SrtFlow/VideoEditFilterLUT.swift
  （Sources/SrtFlow/VideoEditExportGraph.swift 用到了它，编不过）
```

恢复之后转绿。六项 CI 失败本地逐一重跑通过。

## 教训

1. **守卫的作用范围要写进守卫自己的说明里。** 「从源码现算」这句话让人以为它覆盖
   全部依赖，实际只覆盖一个文件。范围不写清楚，下一个人（和下一个我）还会以为
   本地绿就是真绿。
2. **本次扩宽仍有一处盲区，已经写进守卫的开头**：只定义 extension、不定义任何顶层
   类型的文件，这条守卫认不出来（没有类型名可匹配）。所以新功能**别开「只有
   extension」的文件** —— 要么和类型定义放同一个文件，要么里面至少有一个顶层类型。
   滤镜这一刀原本打算把 `extension TimelineState` 单独拆一个文件，正是因为这条
   盲区才没拆。
3. **一个文件混着模型和视图，代价会在自检清单上显出来。** `VideoPreviewView.swift`
   那次混装平时看不出问题，直到给视图加了一个依赖、把一个只测模型的小检查拖下水。
