# 2026-09-28 英文男声的配音开头「啪」地爆音：Kokoro 的 am_fenrir 峰值超过满幅

## 症状

用户用测试版（0.17.1，b4b2034）让自己的 AI 给「素材B课程」配英文旁白（`SrtFlow/配音` 里一句一个 .m4a）：「One. Format your script…」
「Two. Keep your prompts…」「Three. Build character sheets…」这三句开头有明显的爆破音，另外两句（「Master these three…」
「Your AI-generated videos…」）没有。用户：「配音竟然有爆破音，很奇怪啊，之前你测试给我的，都没有」。用户那边的 AI 量出来：三句都是
`en_male`（am_fenrir），前 0.25 秒里峰值顶到 0 dBFS、波形被砍平。

把这几个文件解码成 16 位的 WAV 数一数：顶在满幅上的采样三句分别是 98、1827、2070 个，另外两句峰值 0.75、0.86，没有。

## 根因

- **Kokoro 的 am_fenrir 读出来的原始声音会超过满幅。** 同样意思的五句英文（2026-09-28 本机实测）：am_fenrir 的峰值 −1.4 到 +1.2 dBFS，
  有三句有采样超过 1.0（22、13、4 个）；它说话部分本来就响（−17.4 到 −18.7 dBFS），峰值又比说话响 17–19 dB。别的七个角色的音色峰值
  −2.6 到 −8.6 dBFS，一个都不超。
- **写文件那一步原样照抄。** `AIAudioFileWriter.writeM4A` 拿到 Float32 就交给 AAC 编码器，没有任何电平处理。AAC 本身能存大于 1 的值
  （峰值 1.15 的输入读回来还是 1.15–1.17），可是一播放、一解成 16 位就被砍平 —— 一个个平顶就是那一声声「啪」。
- **为什么之前给用户听的都没有**：
  1. 挑音色时的样音（`~/Downloads/SrtFlow-TTS样音/`）是探针用 speech-swift 的 WAVWriter 写的，句子也不一样；接进 App 之后的端到端只跑了
     zf_xiaoyi、zm_yunxi、af_heart 三个（峰值都在 0.9 以下）。am_fenrir 是用户听完样音才定成 `en_male` 的（方案第 49 条），
     之后没人用生产那条路真跑过它。
  2. 第 ② 刀的 macOS 声音峰值只有 −2.6 到 −4.3 dBFS，那时候撞不上。
  3. 配音的自检全是时间、词、文字、落点，**没有一条量声音本身的电平**。

## 修复

- 新增 `AIVoiceLevel`（纯值）：整句乘同一个增益 —— 说话部分（20 毫秒一格，−45 dBFS 以下不算，停顿不拉低平均）拉到 −18 dBFS，峰值封顶
  −1 dBFS，两样冲突听峰值的，最多放大 4 倍（防一句几乎全是底噪的被放大成噪音）。不压缩、不改音色，和音乐库
  「宁可响度不统一，也绝不压动态」一个口径。
- `AIAudioFileWriter.writeM4A` 改成 `writeVoiceover`：先过 `AIVoiceLevel` 再写，返回写进去的那一份采样。Kokoro（`KokoroVoiceSpeech`）和
  macOS 的声音（`AISpeechSynthesis`）都只经它写文件，词的时间（`AIVoiceWords` 量静音）按它返回的那份算 —— 和听到的一致。
- 顺带的好处：八个音色原始响度差 6 dB（−15.6 到 −21.6 dBFS），统一之后大多数句子只动 1–3 dB，am_fenrir 那种起伏大的先顶到峰值上限、
  比别的轻 1–2 dB；一批旁白换角色音量也齐。
- 长期约束写在 [AI 接口（MCP）](../architecture/ai-control-mcp.md) 第四节第 34 条「音量」。

## 验证

- `checks/MCP/VoiceLevelChecks.swift`（`scripts/check-mcp.sh` 编进自检二进制，10 条）：像 am_fenrir 那样说话在 −18 dBFS 上下、开头一下冲到
  1.15 的一句，出来峰值正好压在 −1 dBFS；调响一句轻的也不冲过上限；普通的一句拉到 −18 dBFS；一响一轻两句出来一样响；停顿不算；
  静音原样；底噪最多放大 4 倍；**生产那一步真写一个 .m4a 再读回来**：峰值不到 0.95、响度和写进去的差不到 0.5 dB、返回的就是调过的那份。
- `scripts/check-mcp.sh` 的扫描：两种声音各恰好一处 `let samples = try AIAudioFileWriter.writeVoiceover(`，自己不开 `AVAudioFile(forWriting`。
- 反向验证：拿掉峰值上限（只按响度）→ 3 条红（1.147、1.559、读回来 1.147）；写文件不过音量 → 2 条红（读回来 1.148）；让 Kokoro 绕开
  `writeVoiceover` → 扫描红。恢复后 254 项全过。
- 真句子：Kokoro 八个音色 × 3–6 句（含「Stop! Don't miss this. Tap, pop, kick…」这种爆破音多的）过 `writeVoiceover` 写成 .m4a 再读回来，
  最高的峰值 0.893（−0.98 dBFS），和写进去的差不到 0.05 dB，所以留 1 dB 够。拿用户那三个**已经削过波**的文件再过一遍，读回来会冒到
  1.077 —— 平顶的波形编码后会多冒 1.7 dB；模型的原始输出不是平顶的，不会这样。
- 这台 Mac 的声音（婷婷、Daniel、Karen）原始响度 −15.8 到 −20.3 dBFS、峰值 −2.6 到 −4.3 dBFS，统一后只动 2 dB 以内。
- 实机：新测试版上按 [人工回归清单](../architecture/ai-control-mcp.md) 第八节「用 en_male 配『One. …』……」那一条听。

## 教训 / 防回归

- **合成器 / 模型给的采样不保证在 ±1 以内。** 写声音文件要有一处统一的电平关口，每一种声音都经它；以后加 fal 这类声音也只许经
  `writeVoiceover` 写文件（扫描钉着现在的两种）。
- **角色换了音色，要用生产那条路把每个角色都真跑几句、量一下峰值和响度**：挑音色时听的样音是另一套写法、另一些句子，不能代表。
- 做声音的功能，自检里至少要有一条量声音本身（电平、峰值），只测时间和文字的自检对「听起来坏了」一声不吭。
