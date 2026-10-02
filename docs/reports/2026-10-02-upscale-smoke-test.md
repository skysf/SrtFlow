# 视频 upscale 实测：六个 fal 模型、八个档位、19 条真素材

> 2026-10-02。方案 [视频 upscale](../plans/2026-10-02-video-upscale.md)，长期约束 [fal.ai 生成](../architecture/fal-generation.md) 第十二节。
> 对象：南极工程前 2 分 03 秒里低于 1080p 的源（1280×720 / 1344×768，24 fps，3–10 秒，H.264 + AAC），整个文件送上去，
> 升到短边 1080，每个源只用一个模型。脚本和对比图在仓库外（`~/Downloads/Sky_Studio_All/fal-video-upscale-reference-2026-10-02/`），
> 账单数字抄在这里，`checks/Fal/UpscaleChecks.swift` 把估价钉在它们上面。

## 结论

| 用途 | 档位 | 为什么 |
| --- | --- | --- |
| 便宜、忠实 | `fal-ai/bytedance-upscaler/upscale/video` standard，`aigc` 预设 | 1080p 每秒 $0.0072、按输出秒精确计费、锐度提升明显不乱加细节、2–3 分钟 |
| 真人脸 | `topaz/upscale/video/precision` Proteus | 一条 $0.10–0.20，眼镜、皮肤、雪点更清楚、不改脸、约 1 分钟 |
| 重绘细节 | `topaz/upscale/video/generative` Starlight Precise 2.6 | 毛发、树叶、水面全部重绘，19 条里视觉提升最大，5 秒 $0.60、3 分钟 |
| 第二家 | `blackforestlabs/flux-video-upscale` precise / creative | 1080p 实测 $0.148 / $0.208 每秒，按输出像素线性；提升中等；输入最长 20 秒、50 MB、只收 mp4 |
| 不采用 | `topaz/upscale/video/creative` | 5 秒十分半钟；$1.50；少了 3 帧 |
| 不采用 | `bria/video/increase-resolution` | 只能 2x / 4x，提升不明显；跑完一个多小时账单里还没出现 |

## 数字

| 文件 | 档位 | 源 → 出 | 帧 源→出 | 耗时* | 估价 | 实收 | 账单 units |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Shot对着镜头南极洲气温 | topaz-precision | 1280×720 → 1920×1080 | 216→216 | 50 s | $0.18 | $0.200 | 20 |
| Shot司机开车说话 | topaz-precision | → 1920×1080 | 192→192 | 56 s | $0.16 | $0.100 | 10 |
| Shot_笑着说这不是我想听的 | topaz-precision | → 1920×1080 | 120→120 | 62 s | $0.10 | $0.100 | 10 |
| Shot_丛林探索 | topaz-precision | → 1920×1080 | 144→144 | 68 s | $0.12 | $0.100 | 10 |
| Shot_丛林熊过河 | topaz-precision | → 1920×1080 | 120→120 | 75 s | $0.10 | $0.100 | 10 |
| Shot_篝火人物近景 | topaz-precision | → 1920×1080 | 72→72 | 81 s | $0.06 | $0.100 | 10 |
| Shot_篝火跳舞 | topaz-precision | → 1920×1080 | 120→120 | 85 s | $0.10 | $0.100 | 10 |
| Shot_红毛猩猩 | topaz-generative | 1344×768 → 1890×1080 | 124→124 | 193 s | $0.62 | $0.600 | 60 |
| Shot_丛林A | topaz-creative | 1344×768 → 1890×1080 | 124→**121** | 627 s | $2.59 | $1.500 | 150 |
| Shot_把汽车慢慢放下 | flux-precise | 1280×720 → 1920×1080 | 144→**145** | 91 s | $0.84 | $0.896 | 11.9476 |
| Shot_鲸鱼 | flux-precise | 1344×768 → 2016×1152 | 158→**157** | 152 s | $0.92 | $1.095 | 14.6002 |
| Shot_汽车冰面A | flux-creative | 1280×720 → 1920×1080 | 144→**145** | 200 s | $1.20 | $1.255 | 16.7267 |
| Shot_汽车冰面B | bytedance-standard | 1280×720 → 1920×1080 | 144→144 | 157 s | $0.04 | $0.043 | 6.016 |
| Shot_C准备跳下去 | bytedance-standard | 1344×768 → 1890×1080 | 243→243 | 121 s | $0.07 | $0.073 | 10.145 |
| Shot_丛林C | bytedance-standard | 1344×768 → 1890×1080 | 158→158 | 165 s | $0.05 | $0.047 | 6.593 |
| Shot_脚踩泥 | bytedance-standard | 1344×768 → 1890×1080 | 158→158 | 129 s | $0.05 | $0.047 | 6.593 |
| Shot_和部落走路 | bytedance-pro | 1344×768 → 1890×1080 | 124→124 | 324 s | $0.37 | $0.373 | 51.85 |
| Shot_fewB_peopleDance | bria | 1344×768 → 2688×1536 | 124→124 | 170 s | $0.73 | 未入账 | — |
| Shot_抱企鹅5秒 | bria | 1344×768 → 2688×1536 | 124→124 | 99 s | $0.73 | 未入账 | — |

\* 19 条约 80 秒内全部提交，耗时含排队。估价按网页标价 × 整段时长（Topaz creative 按 4K 档估）。合计估 $9.04，账单已扣 $6.73（17 条，
`percent_discount` 全是 0），Bria 两条按标价 $1.45 未入账。

## 规律

- **字节**：账单的 units 就是输出秒数，乘 $0.0072（1080p）；pro 是 10 倍；2K / 4K 按网页翻倍。估价可以精确。
- **FLUX**：价目接口说单位是 `seconds` $0.075，但 units 不是秒：三条都严格等于 **每百万像素·秒 $0.0715（precise）/ $0.1001（creative）**，
  按输出面积线性，没有档位台阶；换算到 1920×1080 是 $0.148 / $0.208 每秒，比网页的 $0.14 / $0.20 高 4–6%。
- **Topaz**：价目接口按 `units` 每个 $0.01。precision 1920×1080 24 fps：3.0、5.0、6.0、8.0 秒的各 10 units，9.0 秒 20 units；generative 5.18 秒
  60 units（= 网页 $1.20/10 s 按整秒）；creative 5.18 秒 150 units（= $3.00/10 s 按整秒）。网页标题「1080p 每 10 秒 $0.20」和同页例子
  「1 分钟 $0.80」自相矛盾，并写「credits 每个任务只取整一次」。**不是折扣**。估价按网页每 10 秒价 ÷ 10 × 秒数、向上取整到 $0.10，只高不低。
- **声音**：只有 FLUX 的解码后逐采样和原片相同；Topaz 7 条里 5 条把声音裁到画面长度；字节重采样 44.1 kHz；Bria 重编码且短 0.1 秒。
- **帧数 / 时长**：FLUX ±1 帧；Topaz creative 少 3 帧而声音没短，文件尾有 0.14 秒只有声音；Bria 声音短 0.1 秒。
- **编码**：Topaz 默认 HEVC Main 8-bit、7–22 Mbps；其余 H.264 High 8-bit；全部 yuv420p。
- **接口**：上传走 `POST rest.fal.ai/storage/upload/initiate?storage_type=fal-cdn-v3` 再 `PUT` 到给的地址（`gcs` 已被拒）；
  实际扣费 `GET api.fal.ai/v1/models/billing-events?request_id=…`（ADMIN Key），多数几分钟内出现；价目 `GET /v1/models/pricing?endpoint_id=…`
  只给一个单价，FLUX 的单价和实收对不上，不能直接当估价；估价接口 `POST /v1/models/pricing/estimate` 只按单位数量算、不认视频。

## 画质印象（单帧 100% 裁片，主观）

Topaz generative 的红毛猩猩最漂亮（有一点重绘味）；Topaz precision 的人脸最忠实、最划算；字节 standard 性价比最高，pro 看不出好十倍；
FLUX precise 收敛、creative 更锐但会小改细节；Bria 看不出提升。
