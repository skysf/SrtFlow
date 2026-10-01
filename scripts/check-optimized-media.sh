#!/usr/bin/env bash
# **优化媒体（V1）的自检**：判据是纯函数、关键帧间隔真的扫出来、解码速度量得出、一块真的转出来
# （0.5 秒内必有关键帧、没有 B 帧、尺寸 / 时长 / 帧数对、首尾帧和源一样、不带声音）、缓存按身份存取、超了上限丢最久没用的。
# 素材是 AVAssetWriter 现写的渐变灰视频（不依赖 ffmpeg）。
#
# 用法：
#   scripts/check-optimized-media.sh
set -euo pipefail
cd "$(dirname "$0")/.."

# Rosetta 终端下必须显式指定 arm64，否则会去编 x86_64（见 docs/build/）。
ARCH_FLAG="--arch arm64"
TRIPLE="arm64-apple-macosx15.0"

echo "==> swift build ${ARCH_FLAG} --target SrtFlowCore"
BUILD_OUT="$(swift build ${ARCH_FLAG} --target SrtFlowCore 2>&1)" || { printf '%s\n' "${BUILD_OUT}"; exit 1; }
BUILD_DIR="$(swift build ${ARCH_FLAG} --show-bin-path)"

OUT="$(mktemp -d)/optimizedmedia"
trap 'rm -rf "$(dirname "$OUT")"' EXIT

echo "==> 编译自检二进制"
xcrun swiftc \
  -target "$TRIPLE" \
  -wmo \
  -I "$BUILD_DIR/Modules" \
  -o "$OUT" \
  Sources/SrtFlow/MediaProbe.swift \
  Sources/SrtFlow/AppLanguage.swift \
  Sources/SrtFlow/PerfCounters.swift \
  Sources/SrtFlow/MediaReadQueue.swift \
  Sources/SrtFlow/OptimizedMedia/MediaKeyframeProbe.swift \
  Sources/SrtFlow/OptimizedMedia/DecodeSpeedProbe.swift \
  Sources/SrtFlow/OptimizedMedia/OptimizedMediaPolicy.swift \
  Sources/SrtFlow/OptimizedMedia/OptimizedMediaStore.swift \
  Sources/SrtFlow/OptimizedMedia/OptimizedMediaTranscoder.swift \
  checks/OptimizedMedia/main.swift \
  checks/OptimizedMedia/Fixtures.swift \
  "$BUILD_DIR"/SrtFlowCore.build/*.o

echo "==> 运行"
"$OUT"
