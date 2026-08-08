# 字幕面板的语言流：源语言自动检测与目标语言的可见性合同

来历：[bugfixes/2026-08-06-subtitle-panel-language-defaults.md](../bugfixes/2026-08-06-subtitle-panel-language-defaults.md)
与 [bugfixes/2026-08-09-subtitle-translate-after-same-language.md](../bugfixes/2026-08-09-subtitle-translate-after-same-language.md)
两个案例沉淀的长期约束。改 `SubtitleGenPanel` / `SubtitleTranslationService` /
`TranscriptionTask` 的语言相关逻辑前必读。

## 硬约束

1. **目标语言必须当着用户的面选定。** 任何会被翻译消费的目标语言值，它的
   Picker 必须在消费前可见：翻译区没有字幕轨时整个不渲染；「Translate after
   generating」勾上时当场展开 Target language Picker。不许出现「值被后台
   消费、控件却没渲染过」的组合（2026-08-09 事故）。
2. **翻译入口一律先预检**（`TranslationPreflight`）：源语言已知时，同语种
   （maximal 化后语言码+文字系统相等）与 unsupported 配对在提交前拦下，
   给点名两种语言的文案。同语种判定的合同由
   `checks/TranslationPreflight` 钉住：en ≍ en-US ≍ en-Latn-US；
   区域差异不算区别；**zh-Hans 与 zh-Hant 是两个方向**；yue ≠ zh。
3. **「生成后顺便翻译」遇到同语种 = 跳过，不是失败。**
   `TranscriptionTask.translationSkipNote` 如实说明；字幕生成的成功结局
   不许被注定失败的翻译拖红。真失败（翻了但系统报错）仍走 failed，
   不伪装成功（原有合同不变）。
4. **系统 TranslationError 不许原样透传给用户当解释。** 它对一切失败只说
   "Unable to Translate"（NSError code 恒 1）。macOS 26+ 用公开静态实例 +
   `~=` 分类（notInstalled / unsupported 配对 / 识别不出语言），15–25 才
   允许透传兜底。
5. **源语言默认 Auto-detect，检测是两段式**（macOS 26 的 SpeechTranscriber
   必须显式给语言，系统没有音频语言识别）：
   - 候选按优先级：素材音轨元数据指名的语言（唯一允许触发模型下载的候选）
     → 系统首选 → 其余已装语言；去重、上限 3。**探针不为非元数据候选下载
     模型** —— 自动检测不许静默拉起 N 份模型下载。
   - 单候选直接采用；多候选各转写同一段 20s 探针，按词时长加权置信度裁决
     （`SrtFlowCore/SubtitleLanguageDetection`，SrtFlowCoreChecks 有用例；
     实测正确模型 ≈0.9+，错误模型 ≈0.5–0.6，阈值 0.45 只兜「候选里没有
     正确语言」）。
   - 检测只在候选之间裁决：候选之外的语言（既没装、元数据也没指名）检测
     不出来，失败文案必须引导手选，不许硬猜。
   - 写回 `subtitleCompanion.sourceLanguage` 的一律是**实际转写用的**
     locale（`harvest.locale`），不是面板哨兵值 "auto"。
6. **素材元数据不再预填源语言 Picker**：它是检测的最高优先级候选。Picker
   的非默认值只来自用户亲手选择。

## 人肉回归清单（GUI 冒烟，自动化够不着）

发版前按 docs/testing/gui-smoke-testing.md 过一遍：

- [ ] 新工程开面板：只有「Generate from audio」区，Source language =
      Auto-detect，看不到任何目标语言；勾 Translate after generating 后
      Target language Picker 当场出现。
- [ ] 英文视频 + 目标选英语系语言生成：字幕生成成功，出现「translation
      skipped」通知（灰字 info，不是红字），无「Unable to Translate」。
- [ ] 英文视频 Auto-detect 生成：检测阶段文案出现，最终语言正确，
      companion.sourceLanguage 为真实语言。
- [ ] 中英界面各看一遍新增文案（源语言/自动检测/跳过通知/预检错误）。
