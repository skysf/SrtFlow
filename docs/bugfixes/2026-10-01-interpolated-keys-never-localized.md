# 2026-10-01 录屏设置页的「follows the project」、烧录列表的「· N lines」从没进过表

## 症状

录屏设置页「输出」那一栏写着「24 fps · follows the project」，后半句在中文、西班牙语界面里都是英文；
烧录页文件列表里每个文件后面的「· 3 lines」同样。西班牙语排版复查（2026-09-30 晚）在截图里看见的。

## 根因

两处都是**带插值的键**：`Text("\(fps) fps  ·  follows the project")`、`Text("· \(count) lines")`。
SwiftUI 把 Int 换成 `%lld` 才拿去查表（真实键是 `"%lld fps  ·  follows the project"`），表里没有这一条就原样显示英文。
覆盖守卫对这一类一直是**写明的盲区**（[本地化](../architecture/localization.md)第一节「已知盲区」第一条）：
静态扫描看不出插值的类型，就干脆跳过 —— 跳过等于没人守，这两条从写出来那天起（2026-08、2026-08-12）就没进过表。
同一批还有 `Text("\(rate) kbps")`：单位不用翻，但它照样经查表，按「技术标识进表走恒等」的规矩也该有一条。

## 修复

- 守卫不再跳过：`checks/LocalizationCoverage/Interpolations.swift` 把字面量里每个 `\(…)` 换成 `%lld` 或 `%@`
  各试一遍，有一种写法在每张表里都有就算过；去掉插值之后不含字母的（`"\(a) / \(b)"`、`"#\(n)"`）不用翻，跳过。
  只看直接调用点：`var title: String { "\(rawValue) fps" }` 这种 String 型计算属性是先格式化成「24 fps」再查表，
  键是格式化后的那条（表里本来就有）。
- 三条键进三张表：`· %lld lines`、`%lld fps  ·  follows the project`、`%lld kbps`（恒等）。

## 验证

- 守卫接上、表没补：12 处红（4 条 × 3 张表），其中 `"\(rawValue) fps"` 是 String 属性的误报 → 改成只看直接调用点，剩 3 条。
- 补表之后绿（869 条）。反向验证：从 zh-Hans 表删掉 `"· %lld lines"` → 红在 `BurnInView.swift:536`，恢复 → 绿。
- 真窗口：西班牙语的录屏设置页「24 fps · sigue al proyecto」。

## 教训 / 防回归

- **「写明的盲区」也是盲区**：写进文档不等于有人守。判不出类型就把几种可能都试一遍，比跳过强。
- 插值里的 Int 是 `%lld` 不是 `%d`：表里已有的 `"%d lines"` 是给 `String(format:)` 用的，`Text` 的插值查不到它。
- 长期约束写进 [本地化](../architecture/localization.md) 第一节（已知盲区改成两条）。
