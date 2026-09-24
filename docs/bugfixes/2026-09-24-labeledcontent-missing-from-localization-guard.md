# 2026-09-24 本地化守卫不扫 `LabeledContent`，录屏提示里的「File」一直没翻译

## 症状

中文界面下，录屏「录制未完成」那张提示里有一行标签显示英文「File」
（`ScreenRecordingSetupView` 的 `LabeledContent("File")`）。同一张提示里的「Length」
是中文的。

## 根因

`scripts/check-localization-coverage.sh` 只扫一张写死的调用清单（`Text`、`Label`、
`Button`、`Toggle`……），**`LabeledContent` 不在里面**。录屏设置页引入 `LabeledContent`
时没往清单里补 —— [本地化](../architecture/localization.md) 明写着「新增 SwiftUI 控件类型
时要往守卫的清单里补一行」，但这条规则靠人记。

于是那几处 `LabeledContent` 的键进没进表全凭运气：「Length」「Save to」「Frame rate」
恰好因为别处也用到而在表里，「File」没有。守卫一直是绿的，因为它根本没看这些调用。

导出面板改版要用 `LabeledContent("Title")` / `LabeledContent("Export to")`，按规则先把它
补进清单，守卫当场红在「File」上。

## 修复

- `checks/LocalizationCoverage/main.swift` 的 `localizedCalls` 加上 `LabeledContent`。
- 两张表补上 `"File" = "文件"`。

## 验证

- 补清单之后、补译文之前：守卫红，报 `en 表里没有："File"` / `zh-Hans 表里没有："File"`
  （`ScreenRecordingSetupView.swift:197`）；补上译文后 691 条全绿。
- 反向验证：两张表里同时删掉新加的 `LabeledContent("Export to")` 那条，守卫报
  `VideoEditExportSheet.swift:218` 缺文案；恢复后绿。

## 教训 / 防回归

1. 按「调用名清单」扫的守卫，清单外的一整类调用都是盲区，而且盲区是**静默**的 ——
   看起来全绿。用到一个仓库里第一次出现的 SwiftUI 控件，先去守卫的清单里查一眼。
2. 以后要彻底堵：守卫可以反过来要求「首个实参是字符串字面量的大写开头调用，要么在
   清单里，要么在一张『不是界面文案』的白名单里（`Image`、`Color`、`UTType`……）」，
   新控件第一次出现就会红。这次没做，记在这里。
