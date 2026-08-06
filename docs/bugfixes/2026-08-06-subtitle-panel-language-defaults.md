# 2026-08-06 字幕面板：默认翻译成阿拉伯语，以及点一下就让预览字幕消失

## 症状

挂一份现成的 `.srt` 到工程里，打开「Subtitles」面板，冒烟截图里看到两件事：

1. **Target language 默认是「Arabic (United Arab Emirates) (needs download)」。**
   用户什么都没选，直接点 `Translate All` 就开始下载阿拉伯语模型、把字幕翻成
   阿拉伯语。而这个面板最常见的用法是把外语字幕翻成自己的语言。
2. **列表里每一项都挂着「(needs download)」**，包括本机已经装好的语言。
3. **面板顶部的「Preview track」三段控件在没有译文时也能点。** 选「Translated
   text」或「Bilingual」之后，预览里的字幕**整个消失**，没有任何提示。

计划文档 17.3-6 只记了「目标语言默认值在源语言确定后应重排到已装语言优先
（现取首个字母序）」，实际比这条严重：源语言在「翻译现成字幕」这条路径上
**可能一直是 nil**，所以那个字母序默认值不是「暂时的」，而是最终生效的那个。

## 根因

三个缺陷，都在同一段语言候选表的代码里。

**根因 1：源语言未知时，排序退化成纯字母序。**

`SubtitleTranslationService.targetLanguages(from:)` 本来是按「已装在前、其余
字母序」排的。但源语言为 nil 时，它走的是这条分支：

```swift
if sourceLanguage == nil {
    // 没有源语言时只列全量支持语言（状态标成 supported，选定源语言后再精确）。
    result.append(TargetLanguage(language: language, status: .supported))
}
```

**全表都是 `.supported`**，于是「已装优先」那一层比较恒等，排序整个退化成
`displayName` 字母序 —— 第一个就是 Arabic (United Arab Emirates)。而
`SubtitleGenPanel.reloadTargets()` 取的默认值正是 `targetLanguages.first?.id`。

**根因 2：自动挑的默认值会一直粘着，等不到重挑。**

```swift
if targetLanguageID.isEmpty || !targetLanguages.contains(where: { $0.id == targetLanguageID }) {
    targetLanguageID = ... ?? targetLanguages.first?.id ?? ""
}
```

条件是「空了或者失效了才重挑」。等源语言确定、候选表重排成「已装在前」之后，
那个按字母序挑出来的值**既不空也仍然有效**，于是原样留着 —— 重排了个寂寞。
这里缺的是「这个值是用户选的还是自动挑的」这个信息。

**根因 3：`needsDownload` 拿占位状态当真话。**

```swift
var needsDownload: Bool { status == .supported }
```

源语言未知时 `status` 只是个**占位**的 `.supported`（根本没查过可用性），
`needsDownload` 却照样返回 true，于是对每一个语言都断言了一句没查证的
「需要下载」。

**根因 4：segmented 样式下 SwiftUI 不认逐项 `.disabled`。**

```swift
Picker("Preview track", selection: $project.subtitlePreviewTrack) {
    Text("Original text").tag(SubtitleTrackChoice.original)
    Text("Translated text").tag(SubtitleTrackChoice.translation)
        .disabled(!hasTranslation)      // ← segmented 下不生效（SwiftUI 已知怪癖）
    ...
}
.pickerStyle(.segmented)
```

点下去 `subtitlePreviewTrack` 真的变成 `.translation`，而
`SubtitleExportPlanner.document(for:...)` 对 `.translation` 是
`return translation` —— 没有译文就是 nil，`currentSubtitleText` 跟着返回 nil，
预览字幕**静默清空**。用户完全看不出发生了什么。

## 修复

**排序补一层系统首选语言**（`SubtitleTranslationService`）：按
「已装 → 系统首选 → 字母序」三级排。这样源语言未知、全表状态占位时，
默认值也会落在用户自己的语言上，而不是字母序碰巧排第一的那个。

```swift
private static var preferredLanguageRanks: [String: Int] { /* Locale.preferredLanguages 名次表 */ }
...
return result.sorted {
    if ($0.status == .installed) != ($1.status == .installed) { return $0.status == .installed }
    if preferredRank($0) != preferredRank($1) { return preferredRank($0) < preferredRank($1) }
    return $0.displayName < $1.displayName
}
```

**区分「用户选的」和「自动挑的」**（`SubtitleGenPanel`）：加
`targetLanguageIsUserPicked`，Picker 的 selection 走代理 Binding 在写入时置位；
`reloadTargets()` 改成「只有用户选过且仍然有效才保留」，自动挑的默认值必须
跟着候选表重排走。

**占位状态不许当真话**：`TargetLanguage` 加 `statusIsKnown`，源语言未知时
构造为 `false`，`needsDownload` 改成 `statusIsKnown && status == .supported`。

**没有译文就不显示 Preview track 控件**：与其摆一个点了会出事、又没法置灰的
控件，不如不显示 —— 没有译文时本来也无从选择。同时在读取侧
（`VideoEditView.currentSubtitleText`）补兜底：选中的轨道解析不出文档时回退到
原文轨，宁可显示原文也不要静默空白（译文被删、工程重开都会留下旧的选择值，
隐藏控件挡不住这些）。

## 验证

按 `docs/testing/gui-smoke-testing.md` 做真实窗口验证（改名成 `SrtFlowDev.app`、
env 钩子挂素材、按窗口 ID 截图）。为了造出「有字幕、无译文」这个状态，
把 `SRTFLOW_SMOKE_VIDEO` 扩成支持 `:` 分隔多路径（`addMedia` 本来就按类型分流），
挂 `smoke.mp4:smoke.srt`。

修复前后的面板截图对比：

| | 修复前 | 修复后 |
|---|---|---|
| Target language 默认 | `Arabic (United Arab Emirates) (needs do…)` | `English` |
| 下载标注 | 每项都挂 `(needs download)` | 源语言未知时不再标注 |
| Preview track 控件 | 显示三段，后两段可点、点了预览字幕消失 | 无译文时不显示 |

候选表实际顺序（System Events 读 Picker 菜单项，本机首选语言 en-US, zh-Hans-US）：

```
English, English (United Kingdom), Chinese, Chinese (Taiwan),
Arabic (United Arab Emirates), Dutch, French, German, Hindi, ...
```

系统首选在前、其余字母序，符合预期。

回归：`SrtFlowCoreChecks` 290、`check-project-file` 87、
`check-preview-composition` 13、`check-export-alpha-compositing` 全绿。

## 教训 / 防回归

1. **占位值不能参与「排序 / 判断 / 对用户断言」。** 这次一个占位的
   `.supported` 同时干了三件坏事：让排序退化、让默认值挑错、让界面撒谎。
   造占位值的时候就要把「这是占位」这件事一起带上（本次的 `statusIsKnown`）。
2. **「默认值」和「用户的选择」必须可区分。** 只判断「当前值还有效吗」是不够的
   —— 自动挑的值也一直有效，于是永远不会被更好的默认值替换掉。
3. **SwiftUI 的 segmented Picker 不认逐项 `.disabled`。** 需要禁用某些选项时，
   要么换 `.menu` 样式（`SubtitleExportSection` 里就是这么用的，是仓库现成先例），
   要么干脆不渲染那些选项。**不要**写了 `.disabled` 就以为管用。
4. **「点了没反应」和「点了静默出错」是两码事。** 这次可点的失效选项不是没反应，
   而是让预览字幕整个消失 —— 界面上任何「选了会导致空结果」的入口，读取侧都要
   有兜底，不能依赖入口侧拦住。
5. **UI 缺陷靠读代码看不出来，要真跑。** 这三条都是冒烟截图一眼看见的；
   17.3 里原本只记了其中最轻的一条，而且描述还不准确。
