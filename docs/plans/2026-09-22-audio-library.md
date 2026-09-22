# 音频库（音乐 / 音效）

> 2026-09-22 产品决策草稿。**尚未实施**，当前状态以实施报告和代码为准。
> 相关：[滤镜](../architecture/filters.md)（共用左栏、卡片交互的三个入口）、
> [声音：音量与渐入渐出](../architecture/audio-fades.md)（试听 ducking 的夹紧点）、
> [工程文件与素材重链接](../architecture/video-edit-project-file.md)（`remoteKey` 是第五层线索）。

## 一、目标

左栏的 `[转场 | 滤镜]` 加第三页 **音频**，页内含**音乐**和**音效**两类，都支持搜索。
素材自带 tags，中英双语可搜。音乐先做，音效随后。

方向是**电影配乐**（cinematic / ambient / score），不是流行歌。

## 二、拍过的板（2026-09-22）

| 决定 | 口径 |
| --- | --- |
| 来源 | **两个**：`remote`（R2 按需下载）+ `local`（用户自己导入的目录） |
| 授权政策 | **只收 CC-BY 和 CC0**。NC / SA / ND 一律不收（理由见第十节，SA 那条是为用户挡坑） |
| 音源 | MTG-Jamendo 的元数据 + Jamendo 公开下载端点，**不需要任何 API key / 账号** |
| 署名页 | **必须做** —— CC-BY 的强制义务，不是可选项 |
| 工程引用 | clip 上多一个 `remoteKey`，重链接多一层「从 R2 重新拉」，格式升 **v18** |
| 试听 | **HTTP Range 流播**，不落盘。拖进时间线才真正下载整个文件 |
| 试听与播放 | **不暂停时间线**，允许视频照播 + 试听同响；试听时时间线自动压到 **-12dB**，停止恢复 |
| 落点 | 拖进来**原样落下**，不按工程总长自动裁短（不自作主张） |
| 规格化 | 统一 **48kHz / 192kbps AAC**，响度归一化 **-16 LUFS**（`loudnorm` 双遍） |
| 缓存 | 落 `Application Support`（系统不会自动清），配一个「清理已下载素材」入口 |
| 离线 | manifest 落一份本地缓存；已下载的素材照常可用 |
| 防抄 | bucket 不公开直读 + Worker 网关限速 + manifest 不含真实 URL；**不做** App 侧 HMAC |
| tags | 四组：**情绪 / 场景 / 质感 / 强度**，外加时长、BPM、有无人声 |
| 双语搜索 | tag 在 **manifest 里存双语对照**，不进 `Localizable.strings` |
| 预览区宽度 | 默认宽度调小，可手动拉大 |
| 主窗口侧栏 | **默认窄（只有图标）、可拉宽出文字**；字号调小 |

## 三、两个来源，一套 UI

卡片、搜索、tags、拖拽全部共用；只有"这一条素材在哪"不同。

| | `remote` | `local` |
| --- | --- | --- |
| 清单 | R2 上的 `Audio/manifest.json` | 扫用户指定目录 |
| 文件 | 按需下载，缓存在 `Application Support` | 本来就在用户盘上 |
| tags | manifest 里给好的 | 从文件元数据 + 用户自己标 |
| 丢了怎么办 | 重新拉 | 走现有的四层重链接 |

`local` 让用户能把自己的音乐加进库里 —— 这是产品上的加分项，不只是版权上的退路。

## 四、数据契约：`Audio/manifest.json`

**从第一天起带版本号。** 改结构不带版本 = 炸掉所有老客户端。

```jsonc
{
  "manifest_version": 1,
  "generated_at": "2026-09-22T00:00:00Z",
  "items": [
    {
      "id": "mus_0001",                    // 稳定不变，工程文件存的就是它
      "kind": "music",                     // music | sfx
      "title": "Distant Shore",
      "artist": "…",
      "duration": 184.2,
      "size": 4412160,
      "url": "https://audio.skylu.ai/Audio/Music/mus_0001.m4a",
      "cover": "https://audio.skylu.ai/Audio/Music/mus_0001.jpg",
      "bpm": 72,
      "has_vocals": false,
      "loudness": -16.0,
      "tags": [
        { "zh": "悲伤", "en": "sad",   "group": "mood" },
        { "zh": "回忆", "en": "memory", "group": "scene" },
        { "zh": "钢琴", "en": "piano",  "group": "texture" }
      ],
      "intensity": 2,                      // 1–5
      "license": { "code": "CC-BY-4.0", "by": "…", "src": "https://…" }
    }
  ]
}
```

四条硬约束：

1. **App 只认 `url` 字段给出的完整地址，绝不在代码里拼路径。**
   守住这条，以后从公开域名换到 Worker 网关只是改 manifest，App 一行不动。
2. **`id` 稳定不变。** 工程文件存的是 `id`，改了就是所有老工程集体失链。
3. **tags 是数据不是界面文案**，双语对照放在这里，不进 `Localizable.strings` ——
   tag 会随 manifest 增长，不该每加一个就发一个 App 版本。
   （`localization.md` 那条"写死的文案两张表都配齐"管的是界面文案，不冲突。）
4. **`license` 必填。** 署名义务靠它驱动，漏一条就是漏一次署名。

## 五、工程文件：`remoteKey` 与 v18

`EditClip` 多一个可空字段 `remoteKey`（= manifest 的 `id`）。老工程没有这个键，
按现有的宽容解码回落成 `nil`，**零迁移**。

重链接现在是四层线索（路径 → bookmark → 同目录同名 → 手动指认）。
`remoteKey` 非空的段在四层**之前和之后各加一层**（实现见
[工程文件与素材重链接](../architecture/video-edit-project-file.md) 第四节）：
四层之前先按 id 认领本地缓存里的那份（纯路径判断），四层之后还找不到就异步去 R2
按 id 重新下载。这是 remote 素材相对本地素材的唯一优势，不用白不用。

**只存字段不实现这两层等于没做**：那样 v18 保住的只是一个没人读的键。

## 六、试听

- **流播**：`AVPlayer` 直接吃 `url`，HTTP Range，不落盘。翻库是零下载零占空间的。
- **不暂停时间线**：两路声音同响。时间线整体音量压到 **-12dB**，试听停了恢复。
  压的是**混音器的总增益**，不是逐段改 `audioMix` —— 那会把用户的音量设定写脏。
  夹紧点必须和 `audio-fades.md` 那个**唯一夹紧点**是同一处。
- 没网时流播失败：卡片上标出来，已下载的照常能试听（读本地缓存）。

## 七、素材规格化（离线，我这边跑）

ffmpeg 8.1.1 + `loudnorm`，双遍：

1. 第一遍 `loudnorm=print_format=json` 量出 `measured_I` / `measured_TP` / `measured_LRA`；
2. 第二遍把这三个值喂回去，输出 `-16 LUFS`，转 48kHz / 192kbps AAC。

单遍 `loudnorm` 是前视窗口的动态处理，**结果和双遍不一样**，配乐库要的是确定值。

为什么要做：配乐库最烦的就是每首音量不一样 —— 翻库时一首震耳一首听不见。
代价是有损转有损（源多半已是 mp3/ogg），但对配乐用途听不出来。

## 八、防抄：**现在不做**（2026-09-22 复算后推翻）

原方案是「做 0+1+2 三层」，即把 `Audio/` 从公开域名摘掉、改走一个带限速的
Cloudflare Worker 网关。**复算之后不做了** —— 那层防护挡不住它要挡的东西，
反而制造出一个真正会被打爆的瓶颈。

### 动机不成立：爬虫刷不爆 R2

最初的担心是「爬虫把 bucket 刷爆」。对着 R2 的计费项算一遍就知道不会：

| 计费项 | 价格 | 免费额度 | 这个库（344MB / 159 个对象） |
| --- | --- | --- | --- |
| **出站流量** | **免费** | — | 爬虫下多少都 $0 |
| 存储 | $0.015/GB·月 | 10 GB | **$0** |
| Class A（写） | $4.50/百万 | 100 万/月 | 爬虫不写 |
| Class B（**读**） | $0.36/百万 | **1000 万/月** | 唯一可能被刷的 |

要用完 1000 万次读，爬虫得把全库拖 **6.3 万遍**（≈ 21 TB）。流量免费，所以拖完
这 21 TB 仍然是 $0；之后每再拖一遍全库花 **$0.00006**。要花到 1 美元，还得再拖
17 万遍。

### 加 Worker 反而更容易被打爆

一次操作发几个请求，用生产那两条路径实测过（`AVPlayer` 直吃 URL /
`URLSession.download`，打一个记日志的本地 Range 服务器，文件与库里同规格
4.3MB / 48kHz / 192kbps / `+faststart`）：

| 操作 | 请求数 | 实际发了什么 |
| --- | --- | --- |
| 试听一首（流播） | **3** | `bytes=0-1` 探大小 → `bytes=0-全部` → `bytes=687660-全部` |
| 下载一首（`+` 或拖进时间线） | **1** | 一个不带 Range 的 GET |
| 开面板拉 manifest | 1 | 另有 5 分钟 CDN 缓存 + 本地副本兜底 |

（顺带验明 `+faststart` 是有用的：不加时 AVPlayer 会先拉文件**尾部**找 moov，
多一个请求。封面目前一个都不请求 —— manifest 有 `cover` 字段但面板 UI 没用它。）

一次典型使用（翻库 + 试听 5 首 + 拖 1 首）≈ 17 个请求。两边对照：

| | Worker 免费版 | R2 直读（现状） |
| --- | --- | --- |
| 额度 | **10 万/天** | 1000 万/月 ≈ **33 万/天** |
| 够多少次典型使用 | ~5,800/天 | ~19,000/天 |
| 爬虫拖几遍全库打爆 | **1,265 遍** | 4,200 遍 |
| **超额之后** | **请求开始失败，服务中断到第二天** | 继续服务，按 $0.36/百万计费 |

最后一行是要害：**R2 超额只是开始花一点点钱且不中断，Worker 免费版超额是正常
用户直接用不了**。爬虫打爆 Worker 比打爆 R2 容易 3.3 倍，后果却严重得多。
（「超额即中断」取自 Cloudflare 文档，未实测；真要上 Worker 前值得先确认。）

### 那它本来要保护什么

不是钱，是**选曲和 tags 这份人工整理**。但素材是 CC-BY 的，
**原件谁都能从 Jamendo 免费下** —— 别人真想要，自己跑一遍第三节那套筛选就有了。
真正值钱的是 manifest，而保护 manifest 比保护音频容易得多。

### 现在的口径

1. **不做 Worker 网关。** `Audio/` 继续走 `downloads.skylu.ai` 公开直读。
2. **不做 App 侧 HMAC**（原方案里也不做）：密钥在二进制里，`strings` 一扫就出来。
3. **真观察到异常再说**，而且第一选择不是 Worker，是 **WAF 的 Rate Limiting Rule**
   —— 免费版给 1 条（按客户端 IP、固定窗口），正好够钉在 `Audio/` 这一个前缀上，
   不引入新瓶颈、不多一个部署单元。

**这条决定可以随时反悔，不欠技术债**：App 侧从第一刀起就只认 manifest 给出的
完整 `url`、绝不在代码里拼路径（第四节约束 1，有断言钉着）。将来要换到网关，
改一份 manifest + 配个路由即可，**代码一行不动**。

## 九、UI 三处改动

### 1. 左栏加第三页

`LibraryColumn.Tab` 加 `audio`。分段控件在 196pt 里塞三项，Label 改**纯图标**
（`.labelStyle(.iconOnly)`）+ 即时提示。

音乐 / 音效**不做内层分段** —— 它们本来就是两个 tag，靠筛选区分，省一层控件。

### 2. 预览区默认宽度

`VideoEditView.swift:45` 的 `idealWidth: 700` 调小（`minWidth: 430` 是下限）。

**注意**：`HSplitView` 的 `idealWidth` 只在首次布局生效，AppKit 会 autosave
用户拖过的位置 —— 所以"默认更窄"对已经用过的人不生效。已接受这个行为。

### 3. 主窗口侧栏默认窄

`MainWindowView.swift:131` 的 `navigationSplitViewColumnWidth(min: 196, ideal: 214, max: 280)`
→ min 降到 56–64，ideal 同值。`SidebarToolRow` 按栏宽切 `.labelStyle(.iconOnly)`。

- macOS 的 `NavigationSplitView` **没有原生图标条模式**，得自己测栏宽切换。
- 只有图标时靠 `.instantHelp(section.blurb)` 认路 —— 这条白捡，但现在的 blurb 是
  **功能描述**不是**名字**，只剩图标时要改成"名字 + 描述"。
- 底部 footer（`safeAreaInset(edge: .bottom)`）窄成图标条之后要重新设计。
- 栏宽 AppKit 会 autosave：拉宽过一次以后都是宽的。已接受。
- 顺带的好处：侧栏变窄 = 编辑器多拿 130pt 宽，音频库那一栏的宽度预算跟着松了。

### 4. `showsTransitionLibrary` 改名

它现在管的是整个左栏显隐，加了音频之后名字和语义都不对。顺手改，碰几处调用点。

## 十、授权政策：只收 CC-BY / CC0

### 音源 API 的现实（2026-09-22 实测）

| 源 | 音乐 API | 结论 |
| --- | --- | --- |
| Pixabay | **没有** —— 官方 API 只有图片和视频 | 只能手动一首首下，上不了规模 |
| Jamendo | 有，但要 `client_id`（要注册账号） | **不走这条** |
| **MTG-Jamendo 数据集** | 元数据全在 GitHub raw，**不需要 key** | ✅ **选它** |
| freesound | 有，要 key | 音效那一刀再说（CC0 优先） |

**MTG-Jamendo** 是 UPF 音乐科技组的公开研究数据集：56,639 首 Jamendo 上的 CC 音乐，
带 genre / instrument / mood-theme 三类标签，元数据和 `audio_licenses.txt` 都是
GitHub 上的纯文本。音频本体走 Jamendo 的公开端点按曲下载：

```
https://mp3d.jamendo.com/download/track/<id>/mp32/   →  200 audio/mpeg，无需 key
```

实测下到 track 78304：5.09 MB，mp3 178kbps / 44.1kHz / 立体声 / 228s，**还带内嵌封面**。

### 为什么只能收 CC-BY

全数据集 56,639 首的授权分布（解析 `audio_licenses.txt` 得到，55,615 条有效）：

| 授权 | 数量 | 收不收 | 理由 |
| --- | --- | --- | --- |
| **CC-BY** | 3,122 | ✅ | 署名即可。可商用、可改编、不传染 |
| CC-BY-SA | 9,933 | ❌ | **SA 会传染给用户的成片** —— 见下 |
| CC-BY-ND | 3,303 | ❌ | ND 禁改编，而我们要做响度归一化 |
| CC-BY-NC-SA | 21,399 | ❌ | NC 禁商用 |
| CC-BY-NC-ND | 15,584 | ❌ | 同上 |
| CC-BY-NC | 2,274 | ❌ | 同上 |

三条理由，**第一条最重要**：

1. **SA（相同方式共享）会传染给用户。** 用户把 BY-SA 的音乐配进视频，成片很可能
   构成演绎作品，得按 BY-SA 授权发布。**这是软件绝对不该塞给用户的坑** —— 他用了
   我们库里的音乐，结果自己的片子被迫开源授权，而他根本不知道。
   不是"我们能不能分发"的问题，是"用户会不会踩雷"的问题。
2. **ND（禁止演绎）和我们的规格化冲突。** 格式转换一般不算演绎，但
   **响度归一化改变了音频内容**，在 ND 下有风险。要么放弃归一化，要么不收 ND。
   归一化对配乐库的价值更大（见第七节），所以不收 ND。
3. **NC（非商业）** —— 用户拿 SrtFlow 做商业视频是正常用法，收 NC 等于给用户埋雷。

### 筛选管线（实测漏斗）

| 步骤 | 剩余 |
| --- | --- |
| ① 数据集总曲目 | 56,639 |
| ② 只留 CC-BY | 3,122 |
| ③ + 配乐类 genre（soundtrack / score / ambient / classical / orchestral / atmospheric / darkambient / newage / minimal） | 944 |
| ④ − 歌曲类 genre（pop / rock / folk / hiphop / jazz / metal / blues / …） | 752 |
| ⑤ − 标了 `instrument---voice` 或 `choirs` | 748 |
| ⑥ 时长 1–6 分钟 | 614 |
| ⑦ **每位艺人最多 2 首**（否则库里全是同一个人） | **152**（来自 92 位艺人） |

放宽到每艺人 5 首约有 300+。**第一批取 30–50 首，从这 152 首里挑。**

第 ⑦ 步是必须的：ambient 创作者往往整张专辑一起发，不去重的话头 20 首全是一个人。
第 ⑤ 步只是**减少**人声而不是杜绝 —— `voice` 标签是艺人自愿打的，只有 1,619 首标了，
所以最终还要逐首过一遍（见下）。

### tags 的真实来源（修正上一轮的判断）

上一轮说"Jamendo 的 tags 白捡"，**这个判断打了折扣**：mood/theme 标注只覆盖
`autotagging_moodtheme` 那 18,486 首，而它和"CC-BY + 配乐类"的交集只有 **35 首**。

所以实际分工是：

| tag 组 | 来源 |
| --- | --- |
| **质感** | ✅ 白捡 —— genre + instrument 标签（ambient / soundtrack / classical / piano / synthesizer…） |
| **情绪 / 场景 / 强度** | ⚠️ 大部分要推：响度包络（有无渐强 → epic / 建立感）、动态范围（大 → drama，小 → background）、频谱重心（暗 / 亮）、曲名与专辑名的语义 |
| 时长 / BPM / 有无人声 | ✅ 客观算 —— ffprobe + 包络分析 |

**我不能真的听音频**，这条从头到尾没变。上面那些是可算的客观特征加曲名检索，
够用，但不是"听过"。有疑问的曲子宁可不收。

### 署名页

CC-BY 的**强制义务**，不是"收益大所以做"。没有它这批素材一首都不能用。

要素齐了：`raw.meta.tsv` 有 TRACK_NAME / ARTIST_NAME / ALBUM_NAME / URL，
`audio_licenses.txt` 有现成的署名句（`<曲名> by <艺人> from Jamendo: <链接>`）。

落点建议：manifest 的 `license` 字段驱动，App 内一个列表页 + 指向 skylu.ai 的链接。
**不能靠 LICENSE 文件糊过去** —— 仓库本体是 AGPL-3.0（`vendor/README.md`），
那管的是代码；素材的署名义务是另一件事，各归各管。

## 十一、分刀

**第一刀（只做 remote 音乐）**：manifest + 列表卡片 + 双语搜索 + 流播试听 + ducking
+ 拖进时间线 + `remoteKey` / v18 + 缓存与清理入口。

**不做**：本地库、音效、Worker 网关（先公开直读，但守住第四节第 1 条那个前提）。

理由：数据契约一旦定错，后面三样要跟着返工三遍。

**第二刀**：本地库（同一套 UI，换个来源）。
**第三刀**：音效（freesound CC0 优先）。
**第四刀**：~~Worker 网关 + 限速 + 签名 URL~~ —— **取消**，理由见第八节。
真观察到异常流量时改用 WAF 的 rate limiting rule。

## 十二、检查与回归（AGENTS.md 要求）

自动化必须盖住的：

1. **manifest 解析的宽容性** —— 不认识的字段要忽略、缺字段要有默认值、
   `manifest_version` 高于本 App 支持的要明确报错而不是静默半解析。
2. **双语搜索** —— 中文词命中 `zh`、英文词命中 `en`、大小写不敏感、
   多词是**与**还是**或**（定：与）。
3. **`remoteKey` 往返保真 + v18 登记 + 老工程回落 nil** —— 进
   `checks/ProjectFile/main.swift`，照第 25 节滤镜那一组的写法。
4. **重链接第五层** —— `remoteKey` 非空时优先走它，加进
   `scripts/check-project-file.sh` 的四层重链接那一组（变五层）。
5. **规格化脚本的输出真是 -16 LUFS** —— 真跑 ffmpeg 再量回来，别只断言参数拼对了。
6. **ducking 走的是唯一夹紧点** —— 断言它和 `audio-fades.md` 那个夹紧点是同一处，
   不是另开一套。

**反向验证**：每条守卫都要临时撤掉修复确认变红。

**自动化够不着的（按 [GUI 冒烟流程](../testing/gui-smoke-testing.md) 实机过）：**

1. 边播边试听两路声音的实际听感，ducking 的压低和恢复是否自然。
2. 流播的起播延迟（点一下到出声多久），以及网络差时的表现。
3. 拖音乐卡片到时间线的落点框跟不跟手（SwiftUI 拖放驱不动合成事件）。
4. 侧栏窄成图标条之后的观感、提示够不够认路、footer 长什么样。
5. 预览区默认宽度在新用户首次打开时的实际观感。
6. 缓存清理之后重开老工程，`remoteKey` 是否真的自动拉回来。
