# SrtFlow

[中文](#中文) · [English](#english)

**中文：** SrtFlow 是一款轻量、原生的 macOS 字幕与视频工具：编辑与转换
Text、SRT、WebVTT、ASS、SSA 字幕，把字幕烧进画面，以及在几乎不损失画质的
前提下大幅压缩视频。全部在本地完成，无需云服务。

**English:** SrtFlow is a lightweight, native macOS subtitle and video tool: it
edits and converts Text, SRT, WebVTT, ASS, and SSA subtitles, burns subtitles
into the picture, and compresses video hard without visible quality loss —
entirely on your own Mac, with no cloud services.

## English

### Features

**Subtitles**

- Open, edit, and save `.txt`, `.srt`, `.vtt`, `.ass`, and `.ssa` subtitles.
- Convert between every supported format, one file or many at once.
- Edit cue timing and text, and add or remove cues.
- Link a local video for synchronized subtitle preview.
- Preserve ASS/SSA metadata and styling where the target format allows it.

**Burn subtitles into video**

- Adjustable typeface, size, weight, letter spacing, fill/outline/shadow
  colours, outline width, a solid bar behind the text, nine-position placement,
  and margins.
- Built-in presets (white on black outline, black on white outline, yellow on
  black outline, drop shadow, translucent bar) plus your own saved presets.
- The font list only offers typefaces the renderer can actually load, and marks
  which ones contain Chinese glyphs — so the font you pick is the font you get.
- Sizes are relative to a 1080p frame, so one style looks identical whether you
  export 720p or 4K.
- Preview is a real frame rendered by ffmpeg through the same filter chain as
  the export, so what you see is what you get.
- Batch mode pairs videos with same-named subtitle files automatically.

**Compress video**

- H.264 CRF encoding (the quality-targeted mode: complex shots get more data,
  simple ones less) with a selectable preset — the default is `-crf 23
  -preset slow`, widely considered the visually lossless sweet spot.
- Or the M-series hardware encoder: roughly ten times faster and far easier on
  the battery, at slightly lower quality for the same file size.
- Optional resolution and frame-rate reduction (only ever downward).
- Audio is copied untouched by default; formats mp4 cannot carry fall back to
  AAC automatically.
- `+faststart` for web playback, optional metadata stripping.
- Batch queue with per-file progress, speed, ETA, and size saving.
- The equivalent ffmpeg command is shown and can be copied to a terminal.

**Interface**

- English and Simplified Chinese, either following the system language or
  switched inside the app at any time.

### Requirements

- Apple silicon Mac
- macOS 14 Sonoma or later
- Xcode Command Line Tools with Swift 5.9 or later

### Build and test

```bash
scripts/vendor-ffmpeg.sh   # fetch the bundled arm64 ffmpeg (once)
swift build
swift run SrtFlowCoreChecks
```

Create a release app and DMG:

```bash
scripts/build-app.sh
```

Build products are written to `dist/` and are intentionally excluded from
version control.

### Sharing the app with someone else

The build is ad-hoc signed, not notarised by Apple, so macOS blocks it after the
DMG travels over the network or AirDrop. That block is not cosmetic: even if the
app opens, the ffmpeg inside its bundle gets killed on sight, so compression and
burn-in fail instantly with nothing in the error output.

One command clears it, once, on the receiving Mac:

```bash
xattr -dr com.apple.quarantine /Applications/SrtFlow.app
```

The DMG ships a bilingual `Read Me First` note with the same instruction, and the
app detects the situation and shows the exact command in its status bar.
Handing the app over on a USB drive or over `scp` avoids the flag entirely.

### About the bundled ffmpeg

Video compression and subtitle burn-in are done by ffmpeg, which SrtFlow ships
inside the app bundle at `Contents/Helpers/ffmpeg` and runs as a separate
process. `scripts/vendor-ffmpeg.sh` downloads a native arm64 static build,
verifies its SHA-256, and checks that it really has libass, libx264, and
VideoToolbox before accepting it.

Bundling is deliberate. A subtitle burn-in needs libass, which many ffmpeg
builds omit; and the `ffmpeg` most commonly found in `/usr/local/bin` on Apple
silicon is an x86_64 build running under Rosetta translation, which encodes
roughly twice as slowly. Shipping a verified native build means the app works
out of the box and at full speed. If no bundled copy is present, SrtFlow falls
back to `/opt/homebrew`, `/usr/local`, and `PATH`, and tells you when the
ffmpeg it found is translated or lacks libass.

This costs about 49 MB of app size. ffmpeg is licensed under the GPL v2 or
later, independently of SrtFlow's own MIT licence; see `vendor/README.md` (also
copied into the app as `ffmpeg-LICENSE.md`) for the version, source, and licence
details.

### Privacy

SrtFlow works locally. It has no accounts, analytics, telemetry, or network
service. Linked video paths and recent-file preferences remain on the Mac. The
only network access anywhere in the project is `scripts/vendor-ffmpeg.sh`
downloading ffmpeg at build time; the app itself never goes online.
Environment files, credentials, signing materials, local development settings,
bundled binaries, and build artifacts are excluded from this repository.

## 中文

SrtFlow 是一款轻量、原生的 macOS 字幕与视频工具。

### 主要功能

**字幕**

- 打开、编辑并保存 Text、SRT、WebVTT、ASS 和 SSA 字幕。
- 支持所有格式之间相互转换，可单个也可批量。
- 可编辑时间码与字幕文本，并增删字幕条目。
- 可关联本地视频进行同步预览。
- 在目标格式允许的范围内保留 ASS/SSA 元数据与样式。

**把字幕烧进画面**

- 字体、字号、粗斜体、字间距、文字/描边/阴影颜色、描边宽度、文字底色条、
  九宫格位置与边距，全部可调。
- 内置预设：白字黑边、黑字白边、黄字黑边、白字加投影、白字半透明底条；
  也可以把自己调好的样式存成预设。
- 字体列表只列出渲染器真正能加载的字体，并标注哪些含中文字形 ——
  选了什么字体，烧出来就是什么字体，不会被悄悄替换。
- 所有尺寸以 1080p 画面为基准，同一套样式导出 720p 或 4K 看起来完全一致。
- 预览是 ffmpeg 用**与导出完全相同的滤镜链**渲染出的真实画面，所见即所得。
- 批量模式会按文件名自动把视频和同名字幕配对。

**压缩视频**

- H.264 CRF 恒定质量编码（复杂画面多给数据、简单画面少给），preset 可选；
  默认就是 `-crf 23 -preset slow`，公认的「视觉无损」平衡点。
- 也可以改用 M 系列芯片的硬件编码器：速度约快十倍、几乎不耗电，
  同体积下画质略逊一些。
- 可选下调分辨率与帧率（只降不升）。
- 音频默认原样复制不重压；mp4 装不下的格式会自动转成 AAC。
- 支持 `+faststart`（网页秒开）与剥除无用元数据。
- 批量队列，逐个显示进度、速度、剩余时间和体积节省。
- 界面上直接显示等效的 ffmpeg 命令，可复制到终端使用。

**界面语言**

- 中英双语，可跟随系统，也可以在应用内随时切换。

### 构建要求

- Apple 芯片 Mac
- macOS 14 Sonoma 或更高版本
- Swift 5.9 或更高版本的 Xcode Command Line Tools

### 构建与自检

```bash
scripts/vendor-ffmpeg.sh   # 获取随包分发的 arm64 ffmpeg（只需一次）
swift build
swift run SrtFlowCoreChecks
scripts/build-app.sh
```

构建产物位于 `dist/`，不会提交到版本库。

### 分享给别人时

构建只做了 ad-hoc 签名、没有 Apple 公证，所以 DMG 一经网络或 AirDrop 传输，
macOS 就会拦。这个拦截不只是弹窗那么简单：即使 App 打开了，**包内的 ffmpeg
也会被系统当场杀掉**，压缩和烧字幕会立刻失败，而且错误输出里什么都没有。

在收到文件的那台 Mac 上执行一次这行命令即可：

```bash
xattr -dr com.apple.quarantine /Applications/SrtFlow.app
```

DMG 里附了一份中英文的《首次打开必读》写着同一件事；App 也会自己识别这种情况，
把确切的命令显示在状态栏里。用 U 盘或 `scp` 传则完全不会被打上这个标记。

### 关于随包的 ffmpeg

视频压缩与字幕烧制由 ffmpeg 完成。它被放在 App 内的
`Contents/Helpers/ffmpeg`，以独立进程调用。`scripts/vendor-ffmpeg.sh` 会下载
一份原生 arm64 静态构建、校验 SHA-256，并确认它确实带 libass、libx264 和
VideoToolbox 才接受。

自带一份是有意的选择：烧字幕必须要有 libass，而不少 ffmpeg 构建并不包含它；
另外 Apple 芯片上 `/usr/local/bin` 里最常见的那个 `ffmpeg` 往往是 x86_64 版，
要走 Rosetta 转译，编码速度大约慢一倍。带一份校验过的原生构建，才能做到
开箱即用且跑满速度。如果包内没有，SrtFlow 会依次回退到 `/opt/homebrew`、
`/usr/local` 和 `PATH`，并在找到的 ffmpeg 是转译版或缺 libass 时明确提示。

代价是 App 体积增加约 49 MB。ffmpeg 采用 GPL v2 或更高版本授权，与 SrtFlow
自身的 MIT 授权相互独立；版本、来源与许可详情见 `vendor/README.md`
（同时会拷进 App 内的 `ffmpeg-LICENSE.md`）。

### 隐私

SrtFlow 完全在本地运行，不包含账号、分析、遥测或网络服务。关联视频路径及
最近使用记录只保留在本机。唯一的网络访问是构建时 `scripts/vendor-ffmpeg.sh`
下载 ffmpeg，App 运行期间不联网。本仓库已排除环境变量文件、凭据、签名材料、
本地开发配置、随包二进制和构建产物。

## License

SrtFlow is available under the [MIT License](LICENSE).
