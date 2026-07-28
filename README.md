# SrtFlow

[中文](#中文) · [English](#english)

SrtFlow is a lightweight, native macOS subtitle editor and converter. It supports
Text, SRT, WebVTT, ASS, and SSA files without cloud services or runtime
dependencies.

## English

### Features

- Open, edit, and save `.txt`, `.srt`, `.vtt`, `.ass`, and `.ssa` subtitles.
- Convert between every supported format.
- Batch-convert multiple subtitle files.
- Edit cue timing and text, and add or remove cues.
- Link a local video for synchronized subtitle preview.
- Preserve ASS/SSA metadata and styling where the target format allows it.
- Follow the system language with English and Simplified Chinese localizations.

### Requirements

- Apple silicon Mac
- macOS 14 Sonoma or later
- Xcode Command Line Tools with Swift 5.9 or later

### Build and test

```bash
swift build
swift run SrtFlowCoreChecks
```

Create a release app and DMG:

```bash
scripts/build-app.sh
```

Build products are written to `dist/` and are intentionally excluded from
version control.

### Privacy

SrtFlow works locally. It has no accounts, analytics, telemetry, or network
service. Linked video paths and recent-file preferences remain on the Mac.
Environment files, credentials, signing materials, local development settings,
and build artifacts are excluded from this repository.

## 中文

SrtFlow 是一款轻量、原生的 macOS 字幕编辑与格式转换工具。

### 主要功能

- 打开、编辑并保存 Text、SRT、WebVTT、ASS 和 SSA 字幕。
- 支持所有格式之间相互转换。
- 支持多文件批量转换。
- 可编辑时间码与字幕文本，并增删字幕条目。
- 可关联本地视频进行同步预览。
- 在目标格式允许的范围内保留 ASS/SSA 元数据与样式。
- 界面跟随系统语言，支持英语和简体中文。

### 构建要求

- Apple 芯片 Mac
- macOS 14 Sonoma 或更高版本
- Swift 5.9 或更高版本的 Xcode Command Line Tools

### 构建与自检

```bash
swift build
swift run SrtFlowCoreChecks
scripts/build-app.sh
```

构建产物位于 `dist/`，不会提交到版本库。

### 隐私

SrtFlow 完全在本地运行，不包含账号、分析、遥测或网络服务。关联视频路径及
最近使用记录只保留在本机。本仓库已排除环境变量文件、凭据、签名材料、本地
开发配置和构建产物。

## License

SrtFlow is available under the [MIT License](LICENSE).
