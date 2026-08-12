#!/usr/bin/env bash
# **声音渐入渐出的真实回归**。
#
# 两条生产管线各跑一遍，量真实的音量包络：
#   - 导出：真实的 `VideoEditExportGraph.plan()` → 真跑 ffmpeg → 解码成 PCM。
#   - 预览：真实的 `VideoEditCompositionBuilder.build()` → 用它返回的 audioMix
#     经 AVAssetReaderAudioMixOutput 读 PCM。
# 每组都带「同一条时间线去掉渐变」的反例对照，防止断言在静音素材上假绿。
#
# 用法：
#   scripts/check-audio-fade.sh
#
# 需要 ffmpeg：素材是现造的恒定振幅正弦（假文件过不了真实解码，量不出包络）。
set -euo pipefail
cd "$(dirname "$0")/.."

# Rosetta 终端下必须显式指定 arm64，否则会去编 x86_64（见 docs/build/）。
ARCH_FLAG="--arch arm64"
TRIPLE="arm64-apple-macosx15.0"

echo "==> swift build ${ARCH_FLAG}"
# SwiftPM 的编译诊断走 stdout：静默成功可以，失败必须倾倒完整输出
#（>/dev/null 会把编译错误吞成无字天书，见 docs/bugfixes/ 2026-08-08 CI 首跑案例）。
BUILD_OUT="$(swift build ${ARCH_FLAG} 2>&1)" || { printf '%s\n' "${BUILD_OUT}"; exit 1; }
BUILD_DIR="$(swift build ${ARCH_FLAG} --show-bin-path)"

OUT="$(mktemp -d)/audiofade"
trap 'rm -rf "$(dirname "$OUT")"' EXIT

echo "==> 编译自检二进制"
xcrun swiftc \
  -target "$TRIPLE" \
  -I "$BUILD_DIR/Modules" \
  -o "$OUT" \
  Sources/SrtFlow/VideoEditModels.swift \
  Sources/SrtFlow/VideoEditAudioFade.swift \
  Sources/SrtFlow/VideoEditClipMarker.swift \
  Sources/SrtFlow/VideoEditAnimation.swift \
  Sources/SrtFlow/VideoEditTimelineEdits.swift \
  Sources/SrtFlow/VideoEditTimelineSnap.swift \
  Sources/SrtFlow/VideoEditExportGraph.swift \
  Sources/SrtFlow/VideoEditCompositionBuilder.swift \
  Sources/SrtFlow/VideoEditPrerender.swift \
  Sources/SrtFlow/BurnInWorkspace.swift \
  Sources/SrtFlow/MediaProbe.swift \
  Sources/SrtFlow/AppLanguage.swift \
  checks/AudioFade/main.swift \
  "$BUILD_DIR"/SrtFlowCore.build/*.o

echo "==> 运行"
SRTFLOW_FFMPEG="${SRTFLOW_FFMPEG:-$(pwd)/vendor/ffmpeg}" "$OUT"
