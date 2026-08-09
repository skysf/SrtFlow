# 字幕面板的语言流：源语言自动检测与目标语言的可见性合同

来历：[bugfixes/2026-08-06-subtitle-panel-language-defaults.md](../bugfixes/2026-08-06-subtitle-panel-language-defaults.md)、
[bugfixes/2026-08-09-subtitle-translate-after-same-language.md](../bugfixes/2026-08-09-subtitle-translate-after-same-language.md)
与 [bugfixes/2026-08-09-pr22-review-followups.md](../bugfixes/2026-08-09-pr22-review-followups.md)
三个案例沉淀的长期约束。改 `SubtitleGenPanel` / `SubtitleTranslationService` /
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
     → 系统首选 → 其余已装语言；上限 3。**探针不为非元数据候选下载
     模型** —— 自动检测不许静默拉起 N 份模型下载。
   - **去重按语言，不按 locale 标识符**（`SubtitleLanguageDetection.selectCandidates`）：
     `en_US` / `en_SG` / `en_IN` 是同一种语言的三个地区变体，探针对它们的裁决
     在语言层面等价，按标识符去重会让它们**吃光三个名额**（实测生产算法取到过
     `["en_US", "zh_CN", "en_IN"]` —— 装了日语模型也永远探不到日语）。
     判据是 `languageKey`：maximal 化后的语言码 + 文字系统，
     **与翻译的同语种预检共用同一份实现**（`TranslationPreflight` 委托过去），
     所以 zh-Hans ≠ zh-Hant、yue ≠ zh 在两边一致。
   - **截断前的顺序必须是确定的**：`installedLocales()` 的返回顺序本机实测
     连续两次读都可能不同，已装那一档按 identifier 排序后再进候选表 ——
     否则「哪三个语言进探针」会随机漂移，同一台机器上都不可复现。
   - **每个候选都要过探针，一个也不例外。** 曾经有过「单候选直接采用」的
     捷径，已删（2026-08-09 复审）：候选表是「这台 Mac 装了哪些模型」决定的，
     跟素材说什么语言毫无关系 —— 只装一个模型的 Mac 会把任何语言的视频都判成
     那个语言。多候选各转写同一段 20s 探针，按词时长加权置信度裁决
     （`SrtFlowCore/SubtitleLanguageDetection`，SrtFlowCoreChecks 有用例）。
   - **裁决 fail-closed**：拿不到判决就如实报「检测不出来，请手选」，绝不
     退化成「就它了」。整轨按错误语言生成的乱码字幕，比「检测失败」糟得多。
     - 阈值 `minimumConfidence = 0.80`，由实测反推：正确模型加权分 ≈0.91–1.00，
       错误模型 0.44–**0.74**，判别区间 (0.74, 0.91) 取中段偏保守一侧。
       **这两个边界本身是断言**（`minimumConfidence > 0.74` 且 `<= 0.91`），
       调参前先让它们过。
     - 没有 confidence 的词按具名常量 `unknownConfidence = 0.5` 计，且有一条
       结构性断言钉住 `unknownConfidence < minimumConfidence`：**「系统没给
       证据」永远不许被判成成功。** 平台哪天整体不回报置信度，全候选一起
       跌到 0.5 → 检测失败 → 引导手选，这就是正确结局。
     - 短素材（词数不足）退回全体比较，放宽的只是「谁有资格参赛」，
       **置信度门槛一步不让**。
   - 检测只在候选之间裁决：候选之外的语言（既没装、元数据也没指名）检测
     不出来，失败文案必须引导手选，不许硬猜。
   - 写回 `subtitleCompanion.sourceLanguage` 的一律是**实际转写用的**
     locale（`harvest.locale`），不是面板哨兵值 "auto"。
6. **素材元数据不再预填源语言 Picker**：它是检测的最高优先级候选。Picker
   的非默认值只来自用户亲手选择。
7. **可听快照是检测的唯一素材来源。** 音轨 metadata 查询和探针抽取都只能
   消费本次任务冻结的 `SubtitleAudibleClips.soundClips(in:)` 产物 ——
   那份快照复刻的是 CompositionBuilder 的可听合同（`mainHidden` 跳主轨、
   `lane.isHidden` 跳整轨、`isMuted || volume <= 0` 跳 clip、静帧图片段不算）。
   - **判「有没有声音」只认 `EditClip.hasAudio`**，与 CompositionBuilder /
     VideoEditExportGraph 同一个属性。写成「info 存在且 hasAudio 为假才排除」
     等于把 `info == nil` 当成有声音 —— 宽容解码读回的老工程、探测还没回来的
     导入中素材全是 nil，用户听不到的段落照样被转写。纯音频 clip 的 nil info
     由 `hasAudio` 里的 `isAudioOnly ||` 兜住（2026-08-06 那条回退还在）。
   - **「文件存在」不等于「音轨可读」。** 探针要按快照顺序**逐段真的抽一次**
     （`SubtitleAudibleClips.selectProbe`）：无音轨的视频、半截文件都是文件
     存在的，只挑第一段又不重试的话，后面明明有正常音频轨，整个 Auto-detect
     却当场失败。错误分流照 `collectWindows` 的责任面 —— **素材自己的错换下
     一段，基础设施错误和取消直穿**，不许把「磁盘满」报成「素材不可读」。
   - **查询顺序以最终选定的探针打头**（`metadataOrder(in:probe:)`，
     在探针定下来**之后**才查）：metadata 是最高优先级候选、还是唯一允许触发
     模型下载的那个，它必须来自真正会被听的那段声音。反例（2026-08-09 复审的
     P1）：隐藏的英文主轨 + 可听的日文 overlay —— 英文 metadata 当上首选候选，
     探针抽的却是日文 overlay。
   - **不许再从 `TimelineState` 枚举一套分叉的「声音来源」。**
     `TranscriptionTask.detectSourceLocale` 刻意不收 `TimelineState` 参数，
     让这件事在类型上就做不到；`scripts/check-project-file.sh` 末尾的接线
     守卫再钉一道（禁止 `state.mainClips + state.audioTracks` 复活）。

## 人肉回归清单（GUI 冒烟，自动化够不着）

发版前按 docs/testing/gui-smoke-testing.md 过一遍：

- [ ] 新工程开面板：只有「Generate from audio」区，Source language =
      Auto-detect，看不到任何目标语言；勾 Translate after generating 后
      Target language Picker 当场出现。
- [ ] 英文视频 + 目标选英语系语言生成：字幕生成成功，出现「translation
      skipped」通知（灰字 info，不是红字），无「Unable to Translate」。
- [ ] 英文视频 Auto-detect 生成：检测阶段文案出现，最终语言正确，
      companion.sourceLanguage 为真实语言。
- [ ] **低可信素材 Auto-detect**（例如纯音乐/环境音，或素材语言的模型没装）：
      必须落到「Couldn't confidently detect the spoken language. Pick it in
      the panel and generate again.」，**不许生成任何字幕**。
- [ ] 中英界面各看一遍新增文案（源语言/自动检测/跳过通知/预检错误）。
