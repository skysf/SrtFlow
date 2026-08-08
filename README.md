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
- The font list only offers typefaces the renderer can actually load, marks
  which ones contain Chinese glyphs, and draws every name in its own typeface —
  arrow through the list and the preview follows, so you can judge a font
  without committing to it.
- Sizes are relative to a 1080p frame, so one style looks identical whether you
  export 720p or 4K.
- Two ways to check the result. **Play** runs the real video with the subtitles
  drawn live over it, so you can hear the speech and confirm the timing lines
  up. **Exact frame** is a still rendered by ffmpeg through the same filter
  chain as the export, so the look is pixel-accurate. Either one can be blown
  up to fill the window (Esc to shrink, ⌃⌘F for full screen).
- Dragging a margin slider draws guide lines on the preview showing exactly
  where the margins fall — and therefore where long lines will wrap. They fade
  three seconds after you let go.
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

**Record the screen**

- Record an entire display, a single window, or a custom region, straight into
  the Edit Video timeline.
- Computer audio is captured by default, including sound SrtFlow itself is
  playing. The microphone is optional and lands on its own linked audio track,
  so you can adjust narration without touching the screen audio.
- The recording follows the project frame rate, and captures real pixels — a
  Retina display is recorded at its full resolution, not half.
- The floating Stop controls never appear in the recording. When you record a
  custom region, everything outside it dims while recording so you can see
  exactly what is being captured — that overlay is not recorded either.
- You pick where to save before recording starts; the location is remembered.
  If the app quits mid-recording, the partial file is offered back on next
  launch instead of being silently discarded.

**Interface**

- One window. Compress, burn-in, and batch conversion are sections in a left
  sidebar, so switching between them is a single click and long jobs keep
  running in the background while you work in another section — the sidebar row
  shows their progress.
- Subtitle editing opens in its own document window, which is what keeps the
  native document behaviour: ⌘S, Save As, Revert, version history, and several
  files open side by side.
- English and Simplified Chinese, either following the system language or
  switched inside the app at any time.

### Requirements

- Apple silicon Mac
- macOS 15 Sequoia or later
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

The build is ad-hoc signed, not notarised by Apple, so macOS blocks the first
launch after the DMG travels over the network or AirDrop. The block is not
cosmetic: while the bundle carries the download-quarantine flag, the ffmpeg
inside it cannot run either, so compression and burn-in would fail instantly with
nothing in the error output.

No Terminal needed. On the receiving Mac:

1. Drag `SrtFlow.app` into `/Applications` and open it from there — not straight
   out of the disk image.
2. Double-click it. macOS refuses; dismiss the dialog.
3. Open **System Settings → Privacy & Security**, scroll to Security, and click
   **Open Anyway** next to the line about SrtFlow. Confirm with password/Touch ID.
4. Open SrtFlow again. Everything works from then on — at startup the app clears
   the quarantine flag from its own bundle, which is what frees the bundled
   ffmpeg.

If it opens but compression still fails the instant you start it, macOS is still
holding the helper. This clears it for good:

```bash
xattr -dr com.apple.quarantine /Applications/SrtFlow.app
```

The DMG ships a bilingual `Read Me First` with the same steps, and the app shows
the command plus a button that opens System Settings when it detects the
situation. Handing the app over on a USB drive or over `scp` avoids the flag
entirely.

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
later; SrtFlow itself is licensed under the AGPL v3 and invokes ffmpeg as a
separate process rather than linking against it. See `vendor/README.md` (also
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
- 字体列表只列出渲染器真正能加载的字体，标注哪些含中文字形，并且**每个字体名
  都用它自己的字体写出来**；用方向键在列表里走一遍，预览会跟着一个个变，
  不用点进点出就能挑。选了什么字体，烧出来就是什么字体，不会被悄悄替换。
- 所有尺寸以 1080p 画面为基准，同一套样式导出 720p 或 4K 看起来完全一致。
- 两种核对方式：**播放**是真的放视频、字幕即时叠在画面上，能听着声音确认时间轴
  对不对得上；**精确帧**是 ffmpeg 用与导出完全相同的滤镜链渲染的静帧，外观
  一模一样。两种都可以放大到铺满窗口（Esc 还原，⌃⌘F 进全屏）。
- 拖动边距滑块时，预览上会画出参考线，标明边距的确切位置 ——
  也就是长句会在哪里换行；松手 3 秒后自动消失。
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

**录屏**

- 可录整块显示器、单个窗口或自定义区域，录完直接进「视频剪辑」的时间线。
- 默认录电脑声音（包含 SrtFlow 自己正在播放的声音）。麦克风可选，录进**单独一条
  关联音轨**，调旁白音量不影响画面声音。
- 帧率跟随工程；按**真实像素**捕获 —— Retina 屏录出来是满分辨率，不是一半。
- 浮动的停止控件不会进画面。录自定义区域时，区域之外会盖一层浅遮罩，录制全程
  都看得出边界在哪 —— 这层遮罩同样不会被录进去。
- 开录前就选好保存位置，并记住上次用的目录。录制中途 App 意外退出时，下次启动
  会把那份未完成的文件交还给你处置，而不是悄悄丢掉。

**界面**

- 一个窗口。压缩、烧字幕、批量转换是左侧边栏里的三栏，切换只要点一下；
  切走之后长任务照旧在后台跑，侧边栏那一行会显示进度。
- 编辑字幕单独开文档窗口 —— 这样才保得住原生的文档行为：⌘S、另存为、
  恢复、版本历史，以及同时打开多个字幕文件。
- 中英双语，可跟随系统，也可以在应用内随时切换。

### 构建要求

- Apple 芯片 Mac
- macOS 15 Sequoia 或更高版本
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
macOS 第一次打开时就会拦。这个拦截不只是弹窗那么简单：只要包上还带着下载隔离
标记，**包内的 ffmpeg 也跑不起来**，压缩和烧字幕会立刻失败，错误输出里什么都没有。

不用碰终端。在收到文件的那台 Mac 上：

1. 把 `SrtFlow.app` 拖进 `/Applications`，从那里打开 —— 别直接在磁盘映像里双击。
2. 双击它，macOS 会拒绝打开，把弹窗关掉。
3. 打开**「系统设置 → 隐私与安全性」**，往下翻到「安全性」那一段，会看到一行
   关于 SrtFlow 被阻止的提示，点右边的**「仍要打开」**，用密码或触控 ID 确认。
4. 再打开一次 SrtFlow，从此就正常了 —— App 启动时会清掉自己包上的隔离标记，
   包内的 ffmpeg 也就跟着放行了。

万一打开之后一点「开始压缩」还是立刻失败，说明系统仍然扣着那个辅助程序，
执行这一行可以彻底解决：

```bash
xattr -dr com.apple.quarantine /Applications/SrtFlow.app
```

DMG 里附了一份中英文的《首次打开必读》写着同样的步骤；App 识别到这种情况时，
会把命令和一个「打开系统设置」的按钮一起显示出来。用 U 盘或 `scp` 传则完全
不会被打上这个标记。

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

代价是 App 体积增加约 49 MB。ffmpeg 采用 GPL v2 或更高版本授权；SrtFlow 自身
采用 AGPL v3 授权，并以独立进程调用 ffmpeg，不与其链接。版本、来源与许可详情
见 `vendor/README.md`（同时会拷进 App 内的 `ffmpeg-LICENSE.md`）。

### 隐私

SrtFlow 完全在本地运行，不包含账号、分析、遥测或网络服务。关联视频路径及
最近使用记录只保留在本机。唯一的网络访问是构建时 `scripts/vendor-ffmpeg.sh`
下载 ffmpeg，App 运行期间不联网。本仓库已排除环境变量文件、凭据、签名材料、
本地开发配置、随包二进制和构建产物。

## License

Copyright (c) 2026 SrtFlow contributors.

SrtFlow is licensed under the [GNU Affero General Public License v3.0](LICENSE)
(AGPL-3.0). You may use, modify, and redistribute it under those terms; any
derivative work you distribute — or make available to users over a network —
must also be released under the AGPL-3.0, with source. The bundled ffmpeg is a
separate program under the GPL v2 or later, invoked as a subprocess; see
[About the bundled ffmpeg](#about-the-bundled-ffmpeg).

SrtFlow 以 [GNU Affero 通用公共许可证第 3 版](LICENSE)（AGPL-3.0）授权。你可以
使用、修改、再分发，但分发的衍生作品（含通过网络提供给用户的版本）同样要以
AGPL-3.0 授权并提供源码。随包的 ffmpeg 是以独立进程调用的另一个程序，采用
GPLv2+ 授权。
