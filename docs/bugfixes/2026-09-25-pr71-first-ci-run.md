# 2026-09-25 PR #71 首跑 CI 红了两项：数字可点范围的参照拿错了、滤镜块的接线守卫还钉着旧名字

## 症状

`feat/sound-scenes` 开 PR（#71）后第一次跑全量 CI，5 组里 3 组红：

- 第 1 组：预览性能 ratchet —— 七项全是「进步了但没登记」（没有退步），预期之中：把比对器打印的
  「改好的基线」写进 `checks/PreviewPerf/baseline.json`。这一条不是 bug，顺带在这儿记数。
- 第 3 组：`text-render` 一条红：「数字按定版串（from / to 里更长的那个）算可点范围，滚动中不跳
  （期望 160.83 ±1.0，实际 162.62）」。本机 121/121 全绿。
- 第 4 组：`project-file` 的接线守卫红：「滤镜块的选中态走 `isSelected(filter:)`」在
  `VideoEditTimelineFilterRow.swift` 里找不到。

## 根因

1. **自检的期望值和被测值不走同一条路径。** 那条自检（05fe1bb 加的，第一次上 CI）拿**普通文字
   "365"** 的可点宽度当数字 365 → 90 的期望。可数字元件的数位是 App 自己按最宽的那个数字等宽排的
   （`TextTypesetter.layout` 的 `monospacedDigits`：苹方不认等宽数字特性），普通文字按字体原本的宽度
   排，两者只在碰巧对得上时相等。苹方的数字本来就不一样宽（本机实测 120pt 下「1」47.45、「9」71.96），
   本机能对上是可点范围按墨迹外接框算、差被碰巧抵掉了；CI 的 runner 是 macOS 26.6.2（本机 26.5.2），
   差 1.8pt。自检量的是字体版本的巧合，不是「按定版串算」这条规矩。产品代码没错：可点范围和画出来
   的数字走的是同一套等宽排版。
2. **守卫散在别的脚本、别的组里，改接线时没跟着改。** 滤镜块选中态的接线守卫（652cbfc 加的）在
   `scripts/check-project-file.sh` 里，钉的是时间线的助手 `isSelected(filter:)`。1dd612c 把拖框中的
   实时高亮挪进了块自己（从 `TimelineDragBox` 收框选命中），五种块的新收法都钉进了
   `checks/timeline-drag-wiring/drag-box.sh`，可这条旧守卫在第 4 组，本机只跑了第 1 组的扫描守卫，
   没跑到它。

## 修复

1. 参照物换成「一直停在定版串上的数字」（365 → 365），和被测的走同一条数字排版：365 → 90、90 → 365
   两个方向的可点宽度都得等于它（容差 0.01）；再加一条用例自检：两位数的 90 要明显比 365 窄，不然
   量不出「按谁算」（`checks/TextRender/HitGeometry.swift`）。
2. 守卫改钉新接线：滤镜块的选中态输入是模型里的多选（`isSelected: project.selectedFilterIDs.contains`），
   拖框中的实时高亮从盒子里收滤镜那一类（`$0.filters.contains(filter.id)`）。
3. 性能基线：七项进步写进 `baseline.json` —— 两个场景的 `edits.composition.assetOpen` 1 → 0、12 → 0，
   `basic.ticks.body` 3900 → 3000、`busy.ticks.body` 14213 → 10313，`ticks.canvas` 240 → 120、540 → 240，
   `busy.ticks.update` 1321 → 1081。

## 验证

- 本机：`scripts/check-text-render.sh` 123/123；`scripts/check-project-file.sh` 755 项 + 接线守卫全绿。
- **反向验证**：可点范围改按 `to`（落定的 90）算 → 「365 → 90」红（108 对 156）；改按 `from` 算 →
  「90 → 365」红；滤镜块的选中态改成单选、实时高亮收错一类 → 两条守卫都红。恢复后全绿。
- 推送前按旧名字把 `scripts/`、`checks/` 全 grep 了一遍（`isSelected(…:)`、`dragOffset(`、会话的几个
  旧 `@State` 名），没有别处还钉着旧接线。CI 在同一个 PR 上重跑全量。

## 教训 / 防回归

- **自检的期望值要和被测值走同一条路径算出来。** 拿另一条路径（普通文字 vs 数字元件）当参照，量的是
  两条路径在这台机器、这个字体版本上碰巧相等 —— 本机绿不代表对，CI 的系统和字体版本不一样。
- **接线守卫散在好几个脚本、好几组里。** 改接线之后，按旧名字把 `scripts/` 和 `checks/` 全 grep 一遍，
  别只跑自己改的那个守卫；这次推送前 grep 一下就能看见。
