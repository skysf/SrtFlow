# 2026-08-22 编辑译文时退格删字，整条 cue 从轨上消失

## 症状

在字幕表（或双击浮层）的译文格里改中文字幕，退格删几个错字，**偶发**整条
cue 直接从两条轨上被删掉 —— 正在编辑的那行连文字带时间一起没了。
不是每次，但一旦发生就丢一句字幕（⌘Z 能救回，用户未必意识到）。
顺带的产物：先删光文字再出事的话，工程里会留下空文本 cue，正是
[导出校验失败](2026-08-22-subtitle-export-empty-cue-verification.md)那个案例的数据来源。

## 根因

三个事实叠出来的：

1. 光标进哪一格，那条 cue 就被选中（`VideoEditSubtitleCueRow` 的
   `onChange(of: focusedField)` 调 `onSelect()` —— 这是对的，预览拖框、
   右栏高亮都靠它）。所以**编辑中 = 选中中**。
2. 视频剪辑栏挂着 local keyDown monitor（`VideoEditView.handleEvent`），
   ⌫/fn⌫ = 删除选中的东西。它跑在事件分发**之前**，唯一的让路判据是
   「第一响应者是 NSTextView」。
3. 多行 `TextField`（`axis: .vertical`）+ 中文输入法下，AppKit 的第一响应者
   会**偶发丢掉**（SwiftUI 的 `@FocusState` 还认为格子有焦点，草稿也还开着）。
   丢掉的那一拍，判据 2 失效 —— 用户敲的退格不再进输入框，落进 monitor，
   变成「删除选中的 cue」。空格/V/M 同理会变成播放、切眼睛、打标记
   （架构文档第 11 条早记过这类「打字变快捷键」的表现，这次是删除版）。

⌫ 还有第二条路：monitor 放行后，系统会把它解释成 delete command 沿响应链
送到 `.onDeleteCommand { project.deleteSelected() }` —— 只堵 monitor 等于没堵。

## 修复

「正在编辑字幕文本」有一个比第一响应者可靠得多的判据：**字幕草稿**
（`project.subtitleDraft`，进格子时打开、回车/失焦提交时清空）。两条删除路
都在动手前先问它（`Sources/SrtFlow/VideoEditView.swift`）：

- `handleEvent`：第一响应者判据之后、所有快捷键分发之前，
  `if project.subtitleDraft != nil { return event }` —— 焦点丢失的那一拍，
  按键顶多没反应，绝不改工程。
- `.onDeleteCommand`：`guard project.subtitleDraft == nil else { return }`。

代价（可接受）：焦点真丢了时快捷键短暂失灵，点回输入框或点别处（触发失焦
提交、草稿清空）即恢复 —— 「按键没反应」远好于「整条字幕没了」。
正常流程不受影响：没在编辑时草稿是 nil，⌫ 删选中 cue 照旧。

## 验证

- 新扫描守卫 `checks/subtitle-editing-wiring.sh`（已进 `check-all.sh`）：
  钉住 handleEvent 在快捷键分发前给草稿让路、让路排在 ⌫ 分支之前、
  `.onDeleteCommand` 同一条纪律。
- **反向验证**：分别临时撤掉两处让路，守卫各自当场红；恢复后绿。
- 焦点偶发丢失本身要真窗口 + 输入法，自动化够不着 —— 已加进
  [subtitle-track-visibility-and-layout.md](../architecture/subtitle-track-visibility-and-layout.md)
  的人肉回归清单（中文输入法连续退格删字那条）。

## 教训 / 防回归

- **「第一响应者是文本视图」不是「用户在打字」的完备判据。** SwiftUI 的
  焦点状态和 AppKit 的第一响应者是两套系统，会短暂脱节；全局快捷键的让路
  要问语义状态（草稿开着 = 编辑会话进行中），不能只问 AppKit。
- 同一个按键有几条到达路径（local monitor、`.onDeleteCommand`、菜单快捷键），
  堵一条要把所有路一起查 —— 守卫也要把每条路都钉住。
- 破坏性快捷键与文本编辑共存时，失效方向必须选「快捷键失灵」而不是
  「误删内容」。
