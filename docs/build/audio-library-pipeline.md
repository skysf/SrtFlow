# 音频库素材管线（选曲 → 规格化 → manifest → R2）

> 2026-09-22 第一批（79 首音乐）实跑记录。扩库、换音源、改规格化参数之前必读。
> 产品决策见 [音频库](../plans/2026-09-22-audio-library.md)；App 侧怎么读这份
> manifest 见那份文档第四节和 `Sources/SrtFlow/AudioLibraryManifest.swift`。

脚本都在 `scripts/audio-library/`。全部纯标准库 + ffmpeg，**不装任何依赖**，
也**不需要任何 API key 或账号**。

## 一、音源：MTG-Jamendo 数据集

| 源 | 音乐 API | 为什么没选 |
| --- | --- | --- |
| Pixabay | **没有**（官方 API 只有图片和视频） | 只能手动一首首下，上不了规模 |
| Jamendo 官方 API | 有，但要注册拿 `client_id` | 要账号 |
| **MTG-Jamendo 数据集** | 元数据在 GitHub raw | ✅ **选它** |

MTG-Jamendo 是 UPF 音乐科技组的公开研究数据集：56,639 首 Jamendo 上的 CC 音乐，
带 genre / instrument / mood-theme 三类标签。元数据是 GitHub 上的纯文本，
音频本体走 Jamendo 的公开端点按曲下载：

```
https://mp3d.jamendo.com/download/track/<id>/mp32/   →  200 audio/mpeg
```

实测下到的是 mp3 320k 上限内的原文件（例：track 78304 → 5.09MB / 178kbps /
44.1kHz / 立体声 / 228s），**带内嵌封面**。

## 二、授权政策：只收 CC-BY

全数据集 55,615 条有效授权的分布：

| 授权 | 数量 | 收不收 |
| --- | --- | --- |
| **CC-BY** | 3,122 | ✅ |
| CC-BY-SA | 9,933 | ❌ |
| CC-BY-ND | 3,303 | ❌ |
| CC-BY-NC-SA / NC-ND / NC | 39,257 | ❌ |

三条理由，**第一条和我们自己无关**：

1. **SA（相同方式共享）会传染给用户的成片。** 用户把 BY-SA 的音乐配进视频，
   成片很可能构成演绎作品，得按 BY-SA 授权发布 —— 他用了库里一首歌，自己的片子
   被迫开源授权，而他完全不知道。软件不该塞这种东西给用户。
2. **ND（禁止演绎）和响度规格化冲突。** 格式转换一般不算演绎，但归一化改动了
   音频内容，在 ND 下有风险。归一化对配乐库价值更大，所以不收 ND。
3. **NC（非商业）** —— 用户拿 SrtFlow 做商业视频是正常用法，收 NC 等于埋雷。

**署名是强制的**，不是装饰：`AudioLibraryCreditsView` 是用户履行义务的入口，
署名句由 manifest 的 `license.text` 给出（源站的现成句子，改一个字都可能不再
满足条款）。

## 三、筛选漏斗（第一批实测）

```
scripts/audio-library/fetch-metadata.sh <元数据目录>
scripts/audio-library/pick_tracks.py <元数据目录> --per-artist 3 > candidates.tsv
```

| 步骤 | 剩余 |
| --- | --- |
| ① 数据集总曲目 | 56,639 |
| ② 只留 CC-BY | 3,122 |
| ③ + 配乐类 genre（soundtrack / score / ambient / classical / orchestral / atmospheric / darkambient / newage / minimal） | 944 |
| ④ − 歌曲类 genre（pop / rock / folk / hiphop / jazz / metal / blues / …） | 752 |
| ⑤ − 标了 `instrument---voice` 或 `choirs` | 748 |
| ⑥ 时长 45s–6min | 614 |
| ⑦ 曲名黑词（feat / remix / vocal / cover / live …） | 560 |
| ⑧ **每位艺人最多 N 首** | 176（N=3） |

第 ⑧ 步不能省：ambient 创作者往往整张专辑一起发，不去重的话头 20 首全是同一个人。

第 ⑤ 步只是**减少**人声而不是杜绝 —— `voice` 标签是艺人自愿打的，全库只有 1,619
首标了。所以最终还要人过一遍，有疑问的宁可不收。

## 四、规格化：宁可响度不统一，也绝不压动态

```
scripts/audio-library/fetch.py candidates.tsv <原始目录> [--mood-only]
scripts/audio-library/normalize.py <原始目录> <产物目录>
```

产物：48kHz / 192kbps AAC（`.m4a`）+ 400×400 封面（从源文件内嵌图抽出来）。

**`loudnorm` 的第二遍不能用。** 它的 `linear=true` 只是"尽量"线性 —— 一旦线性
增益会让 true peak 顶破目标，它**自作主张退回 dynamic 压动态**，而且抬高目标 LRA
也拦不住（实测 track 1048289：源 LRA 18.4 → 产物 15.3）。配乐的强弱对比就是它的
全部价值，压平了只剩背景音乐。

所以第一遍只用来**测量**，第二遍自己算增益，用 `volume` 纯增益：

```
太响（want ≤ 0）→ gain = want                      # 降低永远不会削波
太轻（want > 0）→ gain = min(want, max(天花板 − 实测峰值, 0))
```

峰值那一项顶住时这首就到不了 −16 LUFS，**那是对的**。安静的高动态曲子（安静段落
＋几个强音）保持原样，不往下降 —— 再降一次是在惩罚它。实际响度写进 manifest 的
`loudness`，`peak_limited` 标出来。

**验证不看参数看产物**：跑完再量回 I 和 LRA。纯增益下 LRA 数学上不变，量回来差
2dB 以上就是管线出了错，脚本退出码 1。

第一批实测：79 首，**动态被压 0 首**，峰值顶住、到不了 −16 的 13 首。

## 五、tags：一半白捡，一半推

```
scripts/audio-library/analyze.py <产物目录> features.json
scripts/audio-library/build_manifest.py candidates.tsv <产物目录> features.json manifest.json
```

| 组 | 来源 | 可靠度 |
| --- | --- | --- |
| **texture 质感** | genre + instrument 标签 | ✅ 白捡，艺人自己标的 |
| **mood 情绪** | mood 标签优先，没有就从声学特征推 | 标签可靠，推的是启发式 |
| **scene 场景** | mood 标签 + 时长 + 包络形状 | 启发式 |
| **intensity 强度** | 响度 p90 + 起伏，1–5 | 算出来的 |

声学特征全部由 ffmpeg 抽（`ebur128` 包络、`aspectralstats` 频谱重心、
`silencedetect` 首尾静音），Python 只做聚合。**不抽 BPM**：ffmpeg 没有可靠的节拍
检测，而 ambient / score 大多没有明确节拍，硬推的数字会误导筛选。

**mood 标注很稀疏。** `autotagging_moodtheme` 子集只有 18,486 首，它和
「CC-BY + 配乐类」的交集只有 **35 首** —— 所以绝大多数曲子的情绪是推出来的：
频谱重心分暗/亮、起伏幅度分 drama/background、包络斜率认 buildup、尾部静音认
ending。每条 tag 的依据记在 `_why` 字段里供人工复核，**上传前剥掉**。

推不出情绪时按频谱重心兜底给一个（中间档 = 平静）。情绪是翻库最先用的筛选维度，
没有这一组的素材等于藏起来了。

## 六、上传与落点

```
scripts/audio-library/upload.py <产物目录> manifest.json [--dry-run]
```

需要环境里有 `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` / `R2_ENDPOINT`。

```
s3://skylu-downloads/Audio/Music/mus_<id>.m4a          →  https://downloads.skylu.ai/…
s3://skylu-downloads/Audio/Music/covers/mus_<id>.jpg
s3://skylu-downloads/Audio/Music/manifest.json
```

| 对象 | Cache-Control | 为什么 |
| --- | --- | --- |
| 素材、封面 | `max-age=31536000, immutable` | 按 id 命名，内容永不变 |
| manifest | `max-age=300` | 扩库就变；给长了用户看不到新素材，而它才 60KB |

**manifest 最后传**：素材没齐就先上清单的话，用户会看到点了下不动的条目。

第一批实测：157 个对象 / 344MB，零失败。验过 `Accept-Ranges: bytes` 和
`HTTP 206` —— 那是流播试听的前提。

## 七、扩库怎么跑

一到六节按顺序跑一遍即可，脚本都能重复执行（已有的文件跳过）。三件要注意的：

1. **`manifest.json` 是整份覆盖的**，不是增量。扩库时要把旧的 items 一起带上 ——
   漏了的话老工程里那些素材的 `remoteKey` 就找不回来了（重链接会失败）。
2. **`id` 绝不能改。** 工程文件存的就是它。
3. 加 tag 只动 `build_manifest.py` 顶上的 `TAGS` 表（双语放数据里，不进
   `Localizable.strings` —— tag 会随 manifest 增长，不该每加一个就发一次 App）。
