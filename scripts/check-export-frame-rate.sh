#!/usr/bin/env bash
# **真实生产导出滤镜的帧率回归**（计划 §17.3）。
#
# 调用真实的 `VideoEditExportGraph.plan()` 拿生产 ffmpeg 参数，真跑一遍，数输出帧。
#
# 与 check-export-alpha-compositing.sh 的分工（别搞混）：
#   - 那个是手工复制的独立 alpha fixture，守 alpha 合成数学，不调用生产代码，
#     而且只取第一帧 —— 帧率写错它发现不了。
#   - 本脚本走真实生产路径，是「导出真的按工程帧率出片」的唯一回归。
#
# 素材故意造成 10 fps（与 24/30/60 都不同），这样输出帧数只可能来自滤镜里的
# fps，不可能是源帧透传。
set -euo pipefail
cd "$(dirname "$0")/.."

# Rosetta 终端下必须显式指定 arm64（见 docs/build/）。
ARCH_FLAG="--arch arm64"
TRIPLE="arm64-apple-macosx15.0"

echo "==> swift build ${ARCH_FLAG}"
swift build ${ARCH_FLAG} >/dev/null
BUILD_DIR="$(swift build ${ARCH_FLAG} --show-bin-path)"

OUT="$(mktemp -d)/exportfps"
trap 'rm -rf "$(dirname "$OUT")"' EXIT

echo "==> 编译自检二进制"
xcrun swiftc \
  -target "$TRIPLE" \
  -I "$BUILD_DIR/Modules" \
  -o "$OUT" \
  Sources/SrtFlow/VideoEditModels.swift \
  Sources/SrtFlow/VideoEditAnimation.swift \
  Sources/SrtFlow/VideoEditExportGraph.swift \
  Sources/SrtFlow/VideoEditCompositionBuilder.swift \
  Sources/SrtFlow/VideoEditPrerender.swift \
  Sources/SrtFlow/BurnInWorkspace.swift \
  Sources/SrtFlow/MediaProbe.swift \
  Sources/SrtFlow/AppLanguage.swift \
  checks/ExportFrameRate/main.swift \
  "$BUILD_DIR"/SrtFlowCore.build/*.o

echo "==> 运行"
SRTFLOW_FFMPEG="${SRTFLOW_FFMPEG:-$(pwd)/vendor/ffmpeg}" "$OUT"
