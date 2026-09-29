#!/usr/bin/env bash
# **预览上的字幕和烧出来的一样大**（2026-09-29）。
#
# 同一个字号，烧录用的 libass 把它当行高（字体 OS/2 的 usWinAscent + usWinDescent 撑满字号），预览用的 CoreText 把它当
# em，以前预览一直比成片大 15%–40%（Helvetica 85%、中文回退到苹方 71%）。现在预览按每段字实际用到的字体缩
# （SubtitleFontScale）。这里拿预览那个视图离屏渲一张，再照导出那条路（BurnInWorkspace + 同一个 subtitles 滤镜）真烧一帧，
# 量字的高和宽：几种字体、字体里没有的字按回退的那一款（Helvetica 里的中文：本机回退到苹方，CI 没下载苹方就两边一起换冬青黑体；
# 韩文回退到 Apple SD Gothic Neo）、默认样式的粗体、逐词高亮放大。
# 案例：docs/bugfixes/2026-09-29-subtitle-preview-bigger-than-burn.md
#
# 用法：
#   scripts/check-subtitle-burn-size.sh
#
# 需要 ffmpeg（带 libass）：vendor/ffmpeg，或者 SRTFLOW_FFMPEG 指的那个。
set -euo pipefail
cd "$(dirname "$0")/.."

# Rosetta 终端下必须显式指定 arm64，否则会去编 x86_64（见 docs/build/）。
ARCH_FLAG="--arch arm64"
TRIPLE="arm64-apple-macosx15.0"

echo "==> swift build ${ARCH_FLAG} --target SrtFlowCore"
# SwiftPM 的编译诊断走 stdout：静默成功可以，失败必须倾倒完整输出。
BUILD_OUT="$(swift build ${ARCH_FLAG} --target SrtFlowCore 2>&1)" || { printf '%s\n' "${BUILD_OUT}"; exit 1; }
BUILD_DIR="$(swift build ${ARCH_FLAG} --show-bin-path)"

OUT="$(mktemp -d)/burnsize"
trap 'rm -rf "$(dirname "$OUT")"' EXIT

echo "==> 编译自检二进制"
xcrun swiftc \
  -target "$TRIPLE" \
  -I "$BUILD_DIR/Modules" \
  -o "$OUT" \
  Sources/SrtFlow/BurnInSubtitleOverlay.swift \
  Sources/SrtFlow/SubtitleFontScale.swift \
  Sources/SrtFlow/SubtitleFallbackFont.swift \
  Sources/SrtFlow/BurnInWorkspace.swift \
  Sources/SrtFlow/PerfCounters.swift \
  Sources/SrtFlow/MediaFormatting.swift \
  Sources/SrtFlow/AppLanguage.swift \
  checks/SubtitleBurnSize/main.swift \
  "$BUILD_DIR"/SrtFlowCore.build/*.o

echo "==> 运行"
SRTFLOW_FFMPEG="${SRTFLOW_FFMPEG:-$(pwd)/vendor/ffmpeg}" "$OUT"
