#!/usr/bin/env bash
# 图片转静帧的**真实产物**回归：拿 `StillImageClipFactory.conversionArguments()`
# 的生产参数真跑 ffmpeg，量帧数 / 时长 / 尺寸政策 / 静不静 / 多帧输入截断 /
# **解码次数（靠耗时比值）**。
#
# 用法：
#   scripts/check-still-clip-encode.sh
#   SRTFLOW_FFMPEG=/path/to/ffmpeg scripts/check-still-clip-encode.sh
#
# 与 check-project-file.sh 的分工：那个守「工程存盘/重转时政策反推得对」，
# 全是纯值函数，一次 ffmpeg 都不跑 —— 命令写慢了、动图开不了文件，它都发现不了。
set -euo pipefail
cd "$(dirname "$0")/.."

# Rosetta 终端下必须显式指定 arm64（见 docs/build/）。
ARCH_FLAG="--arch arm64"
TRIPLE="arm64-apple-macosx15.0"

echo "==> swift build ${ARCH_FLAG}（拿 SrtFlowCore 的模块和目标文件）"
swift build ${ARCH_FLAG} >/dev/null
BUILD_DIR="$(swift build ${ARCH_FLAG} --show-bin-path)"

OUT="$(mktemp -d)/stillclipcheck"
trap 'rm -rf "$(dirname "$OUT")"' EXIT

echo "==> 编译自检二进制"
xcrun swiftc \
  -target "$TRIPLE" \
  -I "$BUILD_DIR/Modules" \
  -o "$OUT" \
  Sources/SrtFlow/StillImageClipFactory.swift \
  Sources/SrtFlow/MediaProbe.swift \
  Sources/SrtFlow/AppLanguage.swift \
  checks/StillClipEncode/main.swift \
  "$BUILD_DIR"/SrtFlowCore.build/*.o

echo "==> 运行"
SRTFLOW_FFMPEG="${SRTFLOW_FFMPEG:-$(pwd)/vendor/ffmpeg}" "$OUT"
