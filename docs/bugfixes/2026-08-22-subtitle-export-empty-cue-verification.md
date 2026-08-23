# 2026-08-22 带一条空 cue 的工程，VTT/SRT 字幕文件全导不出

## 症状

导出面板勾选 Original VTT / Translated VTT 后点「Export Subtitle Files…」，
红字报 `Subtitle file verification failed for "Shot1.en.vtt"`，一个文件都写不出来。
工程里的字幕在界面上看起来完全正常。

触发条件：字幕轨里存在**文本为空的 cue**。空 cue 是编辑器的合法状态 ——
「+ 新建一行」（合同 7）和「拆分」的后半条（合同 5）生来就是空的，用户删光
一格文字也会留下一条。实机案例的工程里 132 条 cue 有 1 条空的（原文译文同条）。

## 根因

`SubtitleExportPlanner.writeValidated` 的「回读校验」和序列化器对空 cue
**各有一套账**：

- 序列化器（`serializeSRT/VTT`）把空 cue 照写 —— 写出来只剩一个孤零零的时间行；
- 解析器回读时，这个孤时间行仍算一条 cue（文本为空）；
- 校验的期望数却是在调用方**另算**的 `cues.filter { !$0.text.isEmpty }.count`。

于是 132 条写出去、回读 132 条，期望数却是 131 —— 差 1，好文件被报成坏的。
两套规则各写一份，分叉只是时间问题。

同场检查还发现一个姊妹隐患：cue 文本**内部的空行**（SRT/VTT 里空行是块分隔符）
照写会把一条 cue 劈成两块，后半没有时间行、回读时被整段丢掉 —— cue 数恰好
对得上、校验绿灯，内容却悄悄少了半截。

## 修复

规则收回序列化器一处（`Sources/SrtFlowCore/SubtitleCodec.swift`）：

1. 新增 `SubtitleSerializer.blockLines(_:)`：写块格式前统一算「真正落进块里
   的行」—— 去 ASS 标签、拆行、丢掉空白行。
2. `serializeSRT/VTT` 与 `serializeText`（带时间分支）按它写：空 cue 整条跳过
   （不写孤时间行），文本内空行清掉（不劈块）；SRT 序号按**写出的** cue 连续编。
   跳过只发生在写盘，不改模型 —— 空 cue 在编辑器里继续合法存在。
3. 新增 `SubtitleSerializer.emittedCueCount(_:format:)`：序列化产物回读后应有
   的 cue 数，与各序列化器的跳过规则同源。`writeValidated`
   （`Sources/SrtFlowCore/SubtitleExportPlanner.swift`）的期望数改为问它，
   **调用方不许再自算一份**。ASS/SSA 的 Dialogue 行不怕空文本，逐条照写照读，
   期望数 = 全部 cue。

## 验证

- SrtFlowCoreChecks 新增守卫（字幕导出规划器一节）：空 cue 居中的三条文档
  VTT/SRT 都要能写、回读 2 条、SRT 不给跳过的 cue 留号；文本带空行的 cue
  回读仍是 1 条且两截文本都在；ASS 空 cue 逐条回得来。
- **反向验证**：临时把期望数改回 `!text.isEmpty` 那份、VTT 序列化器改回照写，
  守卫当场红，报的正是用户看到的
  `Subtitle file verification failed for "empty-cue.vtt"`；恢复修复后 715 项全绿。
- 实机：用户工程（132 条含 1 条空 cue，en → zh-Hans-CN）导出
  Original VTT + Translated VTT 成功，文件各 131 条。

## 教训 / 防回归

- **同一条规则只能有一份实现。** 「哪些 cue 会被写出去」属于序列化器；校验、
  预检、计数都必须去问它（`emittedCueCount`），在调用方按 `text.isEmpty`
  之类的判据重算一份，分叉只是时间问题。
- 校验报错时先怀疑「两套账」，再怀疑数据坏了 —— 这次文件与数据都没坏，
  坏的是期望值。
- 块格式（SRT/VTT）里空行是**结构字符**：cue 文本要进块，必须先按块的
  语法消毒，不能原样拼接。
