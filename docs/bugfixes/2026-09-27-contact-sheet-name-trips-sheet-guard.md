# 2026-09-27 拼图函数叫 `sheet(`，被 sheet 语言守卫当成了 SwiftUI 的 `.sheet`

## 症状

PR #81 加上 look（「看」）之后，CI 第 1 组红在扫描守卫上：

```
✗ Sources/SrtFlow/AILookTool.swift:166 .sheet 的内容没套 .appLanguage()（sheet / popover 不继承应用内语言）
```

那一行是 `AIContactSheet.sheet(labelled, size: size)`：把几帧拼成一张 JPEG 回给 AI，什么界面都不弹。本机只跑了
和 MCP 相关的检查，没跑这条守卫，推上去才红。

## 根因

`checks/presented-views-app-language.sh` 按调用名扫：凡是 `.sheet(` / `.popover(` 开头的调用，内容都得套
`.appLanguage()`（[sheet 全是英文](2026-09-24-sheets-ignore-in-app-language.md)那次定的）。它看不出 `.sheet(`
前面是 SwiftUI 视图还是一个自己的类型 —— 拼图的函数正好也叫 `sheet(`（contact sheet 的 sheet），就被当成了弹出的
sheet。守卫的判断没错（宁可误报），错在名字撞上了它认的那个词。

## 修复

函数改名为 `AIContactSheet.draw(_:size:)`（`AILookTool`、`checks/MCP/LookChecks.swift` 跟着改）。它不弹东西，
没有「应用内语言」可套，套 `.appLanguage()` 反倒是在骗守卫。

## 验证

- 本机 `checks/presented-views-app-language.sh` 转绿（14 处都套了）；CI 第 1 组在 001db65 转绿。
- 反向：名字改回 `sheet(`，守卫当场按行号点名 —— CI 那一次红就是这条反向验证。
- 顺手把 `checks/` 下全部扫描守卫在本机跑了一遍（都是 grep 类，秒级），全绿。

## 教训 / 防回归

- **按调用名扫的守卫，名字就是接口。** 新写的函数别取 SwiftUI 修饰器的名字（`sheet`、`popover`、`overlay`、
  `help` 之类）—— 仓库里好几条守卫是按这些名字扫的，撞名的普通函数会被当成修饰器。
- 推之前，除了直接相关的自检，把 `checks/*.sh` 的扫描守卫也跑一遍：秒级，比等一轮 CI 快得多。
- 守卫本身不改：按名字宁可误报、不许漏报；误报的代价是改一个名字。已记进
  [本地化](../architecture/localization.md)的已知盲区一节。
