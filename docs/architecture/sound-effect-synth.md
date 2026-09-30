# 合成音效：SrtFlow 自己做的剪辑动效音（AI 用 `add_clips` 的 `sound_effect`）

> 2026-09-30 起生效。方案、拍过的板、三轮试听和决策门见 [音效方案](../plans/2026-09-30-sound-effects.md)；这里只放长期约束。
> 相关：[AI 接口（MCP）](ai-control-mcp.md) 第四节第 43 条、[阻塞的媒体读取](blocking-media-reads.md)、
> [音频库方案](../plans/2026-09-22-audio-library.md)（录音素材库是另一块）、[写代码的规范](coding-standards.md)。

## 一、是什么、在哪

- 纯 Swift 的合成器，`Sources/SrtFlow/SoundEffects/`：地基 `SoundEffectDSP`（随机数、噪声、振荡器、RBJ 双二阶）、
  `SoundEffectBuffer`（立体声缓冲、归一、K 加权响度）、`SoundEffectReverb`（Freeverb、按峰值比例混、限尾巴）、
  `SoundEffectPreset`（预设清单、参数、渲染入口）、三个预设文件 `SFXAirPresets` / `SFXHitPresets` / `SFXTonePresets`。
  不引第三方，不用 AudioUnit（离线渲染不确定、不好测）。
- **16 个预设**：whoosh、swoosh、suction、riser、downlifter、impact、boom、hit、pop、click、tick、ding、sparkle、beep、glitch、shutter。
  **只做剪辑动效音，不做真实拟音和环境声**（海浪、人群、脚步合成不像：录音素材库或 fal）。
- 给 AI 的入口是 `add_clips` 的 `sound_effect` 条目（`AISoundEffectRequest` 读参数、`AISoundEffectTool` 渲染写文件、
  `AITimelineTools.addClips` 放上时间线），不另开工具（[AI 接口](ai-control-mcp.md) 第一节第 5 条）。
  旋钮五个：`duration`、`pitch`（倍数）、`brightness` 0–1、`size` 0–1（干 / 房间 / 大厅）、`variation`（变体种子）；外加段的 `volume_db`。
- 文件放 `<起点>/SrtFlow/音效`（`AIWorkspace.Output.soundEffects`，名字跟 App 语言），AAC .m4a、48 kHz 立体声。

## 二、硬约束（改动前读）

1. **落点 `hit_at` 是合同。** 每个预设声明自己「最响的那一刻」在第几秒（`SoundEffectRender.hitAt`）：whoosh 在 60%、
   riser / suction 在结尾、impact / hit / pop 在开头、downlifter 在涌起到顶那一刻；sparkle / glitch 这种一串的，落点是**起点**
   （`hitKind: .onset`，之后堆起来更响是设计）。AI 给的 `hit_at` 是时间线秒，工具反算开头（`AISoundEffectRequest.placement`：
   start = hit_at − hitAt，负了就从声音中间开始放、源内偏移补上），结果里报出时间线上的 `hit_at`。自检钉着实测峰值离声明落点
   ≤ 25 ms（噪声主导的 whoosh / swoosh / riser / downlifter ≤ 120 ms）。**改声音设计时先保住这一条。**
2. **混响按干声峰值的比例混**（`SFX.mixReverb`：湿声峰值 = 干声峰值 × 比例 × size）。Freeverb 的湿声增益随房间大小变得很厉害
   （大房间对持续输入的稳态增益近 9 倍），按固定系数混时 impact / ding 的峰值被混响堆起来推后 100–400 ms、suction 的峰值跑到
   结尾前 200 ms，落点就不准了。
3. **电平两道，都在合成器里**（`SoundEffectSynth.render` 收尾）：峰值 −1 dBFS 封顶，再把 BS.1770 K 加权的最大瞬时响度
   （400 ms 窗）压到 **−9 LUFS** 以下 —— 纯音调的声音峰值一样时听着比噪声响得多（ding 曾比 whoosh 响 7 dB，用户说太响）。
   −9 定在用户点头的 whoosh / impact 上，它们只由峰值封顶。放上时间线段的默认音量 **−8 dB**（文件原样放会盖过人声），AI 用 `volume_db` 改。
4. **确定性与文件名。** 种子 = 预设名 + variation（`SFXRandom.seed`）；参数三位小数进 `canonical`；文件名 = 预设名 +
   （参数 + `SoundEffectSynth.version`）的哈希（`fileStem`）。同参数 = 同文件：已经在就不再渲不再写（不算覆盖、不用问）。
   **改了任何预设的声音设计就把 `version` +1**（不然旧文件被当成同一个声音复用），**并且要再渲样音给用户听**
   （2026-09-30 用户逐个听过三轮才定稿，声音好不好听自动化够不着）。
5. **默认都短。** 用户原话「就像别的，裁剪到就开始那一次声音就可以了」：默认时长在 `SoundEffectPreset.defaultDuration`
   （0.05–2 秒）；尾巴按 −60 dB 裁、末尾 10 ms 淡出（suction 2 ms，结尾就是落点）；riser / downlifter / ding 的混响尾巴不靠门限裁
   （还是太长），固定只留 dur + 0.35–0.4 秒再淡出（`SFX.limitTail`）。
6. **写文件只经 `AIAudioFileWriter.writeSoundEffect`**（同配音：音量和格式只有一处说了算）；**渲染 + 写盘在
   `MediaReadQueue.analysis` 上跑**（几十毫秒的纯计算也不占 Swift 并发的线程池）。两条 `scripts/check-mcp.sh` 扫描钉着。
7. **词表只有一份要对账**：小程序的 `MCPVocabulary.soundEffectPresets` 和 App 的 `SoundEffectPreset.allCases` 逐项相等
   （`ConfigChecks` / `SoundEffectChecks`）；预设名只用英文小写单词。
8. **AI 的顺序（用户定）**：先 `find_audio` 找录音（音效库做完之后）、没有合适的用 `sound_effect` 合成、真实声音都没有才
   `generate_media`（配了 fal 才有）。`find_audio`、`generate_media` 的说明和风格卡都这么写。

## 三、参照文件量出来的形状（riser / downlifter 第二版的依据）

第一版 riser 是 3 个锯齿往上爬 + 越来越快的颤音，用户听着「不舒服、不自然」。改前先量了 ElevenLabs 那批（每 100 ms 的 RMS、
频谱重心、频谱平坦度、左右相关、结尾形状）：

| 文件 | 形状 |
| --- | --- |
| `Kinetic_Lift`（4 s） | 音量按 dB 线性升（−57 → −16 dB）；重心 1 → 5.4 kHz、平坦度 0.05 → 0.5（偏音调、暗 → 宽噪声、亮）；左右相关 ≈ −0.1；结尾平着到顶、到头就切 |
| `The_Descent`（4 s）、`Ominous_Descent`（10 s） | 都是**低音音调**「涌起到 21% 处最响，再一路掉到无声」，重心 80–400 Hz、平坦度 0，不是噪声 |

第二版照这个做：riser 是两路独立噪声过打开的低通 + 抬高的高通、一条 Q = 3 的带通噪声、一层很软的音调升一个八度，
音量 −36 → 0 dB 按 dB 线性；downlifter 是低音音调涌起再往下掉、气声暗下去。量回来的曲线和参照重合，用户第二轮通过。
**再改这两个预设，先量、再做、再听。**

## 四、已知不足

- 变体只换随机数和 ±5–10% 的抖动；没有 ADSR、没有自定义波形，五个旋钮就是全部。
- 落点的容差按预设分两档，噪声主导的 120 ms 是「最响的那个采样」的随机性，不是听感上的偏差。
- 音效库（方案第五节的第 2、3 个 PR，2026-09-30 做完）：`find_audio kind=sound_effect` 能搜到 63 条录音 / 制作好的，
  `add_clips {library_id, hit_at}` 按清单里的 `hit` 放；默认音量和合成的同一个 `SoundEffectClipGain`。AI 的顺序：先搜库、再合成、再 fal。

## 五、回归与人工清单

- 自检：`scripts/check-mcp.sh` 的 `SoundEffectChecks`（16 个预设：渲得出、峰值 / 响度封顶、落点在声音里且实测峰值离它不远、
  末尾淡完、无 NaN；同参数逐采样一致、换 variation 就不同、同参数同文件名；whoosh 先升后降、riser / suction 升、downlifter 降；
  参数范围；`sound_effect` 条目怎么读、落点怎么算开头；词表对账、总说明提到它）+ 两条扫描（第二节第 6 条）。
- 人工（发版前）：
  - [ ] 听一遍 16 个预设（原型的顺序：whoosh、swoosh、suction、riser、downlifter、impact、boom、hit、pop、click、tick、ding、sparkle、beep、glitch、shutter）。
  - [ ] 让 AI 「在 12.0 秒的切点上放一个 whoosh」：时间线上块的最响处压在 12.0 秒、块开头在前面约 0.55 秒；结果里 `hit_at` = 12.0。
  - [ ] 同参数再放一次：`SrtFlow/音效` 里不多出文件。
