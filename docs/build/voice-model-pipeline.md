# 本机配音模型（Kokoro）的整理与上传

> 2026-09-28 起。MCP 第 5 块第 ③ 刀：SrtFlow 自己的声音用 Kokoro-82M 的 CoreML 版，模型**不打进 App**，用户在设置 → AI 里
> 点下载（或者 AI 调 `add_voiceover download_voices=true`）时从我们自己的 R2 下（方案第 44、48、50、51 条）。
> 这里写怎么把模型整理好传上去；App 里怎么下、怎么读见 [AI 接口（MCP）](../architecture/ai-control-mcp.md) 第四节第 35 条。
> 和音乐库一样是制备素材，**不在 `check-all.sh` 里**。

## 一、落点

```
s3://skylu-downloads/Models/Kokoro-82M-CoreML/v1/<相对路径>   →  https://downloads.skylu.ai/Models/Kokoro-82M-CoreML/v1/<相对路径>
s3://skylu-downloads/Models/Kokoro-82M-CoreML/v1/manifest.json
```

- App 里写死的是 `KokoroVoicePack.baseURL`（`Sources/SrtFlow/KokoroVoicePack.swift`），两边必须一致。
- **换模型就换文件夹（v2），不覆盖 v1**：已经装好的用户照旧用自己那一份，新版 App 改 `baseURL` 指到 v2。
- 文件按版本号放、内容永不变：`Cache-Control: public, max-age=31536000, immutable`；清单 `max-age=300`。
- 清单最后传：文件没齐就先上清单，用户会下到一半找不到文件。

## 二、来源（钉版本）

| 什么 | 从哪来 | 授权 |
| --- | --- | --- |
| 主模型 `kokoro_5s.mlmodelc`、英语补拼写的 `G2PEncoder` / `G2PDecoder`、词表、英语词典、54 个音色 | huggingface.co/aufklarer/Kokoro-82M-CoreML @ `f8ff771e4cab0bb3368e8af3a090a7e847485401`（权重来自 hexgrad/Kokoro-82M） | Apache-2.0 |
| 法、葡、印地的词典 `dict_*.json` | github.com/soniqo/speech-swift @ `e345dbf95e7bb6c7b51d3f06175360188fa33d1e` 的 `Sources/KokoroTTS/Resources` | Apache-2.0（词条来自 ipa-dict，MIT） |

speech-swift 原来从 `Bundle.module` 读这三份词典；打好的 SrtFlow.app 里没有那个 bundle，会直接崩，所以改成和模型放在一起下载。

## 三、步骤

1. 下模型：Hugging Face 上那个仓库按上面的提交整个下下来（speech-swift 自带的下载器会拒绝带子文件夹的文件名，
   2026-09-28 是用一段自己写的脚本按 `api/models/<repo>/tree/main?recursive=1` 逐个下的）。
2. 整理 + 生成清单：

   ```
   scripts/voice-models/prepare-kokoro.py --model <下好的模型目录> --dicts <speech-swift 的 Resources> --out <整理好的目录>
   ```

   只拷 App 用得到的文件，外加一份署名 `NOTICE.md`；清单里每个文件写相对路径、大小、SHA-256。2026-09-28：77 个文件、333.4 MB。
3. 上传（凭证见下一节）：

   ```
   set -a; source ~/.config/srtflow/r2.env; set +a
   scripts/voice-models/upload.py <整理好的目录>            # 传完自动从公开地址核对
   scripts/voice-models/upload.py <整理好的目录> --verify-only
   ```

## 四、凭证

- 三个环境变量 `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` / `R2_ENDPOINT`，签名代码只有 `scripts/r2.py` 一份（音乐库的上传也用它）。
- 放在**仓库外**的 `~/.config/srtflow/r2.env`，权限 600，令牌只给 `skylu-downloads` 这一个桶的读写（方案第 51 条）。
  不放仓库里的 `.env.local`：虽然被 .gitignore 忽略，AI 在仓库里全局搜索时可能把密钥打印进对话记录，复制整个项目文件夹也会带走。
- 让 AI 跑上传时，它只 `source` 这个文件、不打印内容。

## 五、坑

- **公开域名前面有 Cloudflare，Python 默认的 User-Agent（`Python-urllib`）会被拦成 403**：2026-09-28 第一次上传其实成功了，
  最后「从公开地址读回来核对」那一步报 403。核对时带自己的 User-Agent（`upload.py` 的 `USER_AGENT`）；App 用系统的网络库，不受影响。
- 公开域名和 S3 接口是两条路：传上去（S3 回 200）不等于用户下得到，所以上传脚本最后一定从公开地址读回来核对大小，
  App 下载完再逐个核 SHA-256。
