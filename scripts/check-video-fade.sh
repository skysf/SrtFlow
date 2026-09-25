#!/usr/bin/env bash
# **上层视频轨 + 画面渐变的真实回归**。
#
# 调真实的 `VideoEditExportGraph.plan()` 拿生产 ffmpeg 参数，真跑一遍导出，
# 再抽帧量整幅亮度。断言里的数与 `scripts/check-preview-composition.sh` 中
# 同一场景**对齐** —— 两条管线同账是这套东西的核心合同。
#
# 守三条契约（改 VideoEditExportGraph 的上层轨滤镜段之前必读）：
#   1. 上层视频轨默认等比铺满画布居中，两侧留空露出下层（不是画中画小框，
#      也不补黑）；
#   2. 画面渐变在 alpha 上做，露出来的是下面那一层；
#   3. 主轨接缝上有转场时，那一边的渐变让位给 xfade，不叠加。
#
# 用法：
#   scripts/check-video-fade.sh
#
# 需要 ffmpeg：素材是现造的纯色视频（假文件过不了真实解码，抽不出帧）。
set -euo pipefail
cd "$(dirname "$0")/.."

# Rosetta 终端下必须显式指定 arm64，否则会去编 x86_64（见 docs/build/）。
ARCH_FLAG="--arch arm64"
TRIPLE="arm64-apple-macosx15.0"

echo "==> swift build ${ARCH_FLAG} --target SrtFlowCore"
# SwiftPM 的编译诊断走 stdout：静默成功可以，失败必须倾倒完整输出
#（>/dev/null 会把编译错误吞成无字天书，见 docs/bugfixes/ 2026-08-08 CI 首跑案例）。
BUILD_OUT="$(swift build ${ARCH_FLAG} --target SrtFlowCore 2>&1)" || { printf '%s\n' "${BUILD_OUT}"; exit 1; }
BUILD_DIR="$(swift build ${ARCH_FLAG} --show-bin-path)"

OUT="$(mktemp -d)/videofade"
trap 'rm -rf "$(dirname "$OUT")"' EXIT

echo "==> 编译自检二进制"
xcrun swiftc \
  -target "$TRIPLE" \
  -wmo \
  -I "$BUILD_DIR/Modules" \
  -o "$OUT" \
  Sources/SrtFlow/VideoEditModels.swift \
  Sources/SrtFlow/VideoEditSoundSceneRecipe.swift \
  Sources/SrtFlow/VideoEditSoundSceneDSP.swift \
  Sources/SrtFlow/VideoEditSoundSceneTrack.swift \
  Sources/SrtFlow/VideoEditSoundSceneTails.swift \
  Sources/SrtFlow/VideoEditAudioMix.swift \
  Sources/SrtFlow/VideoEditSoundScene.swift \
  Sources/SrtFlow/PerfCounters.swift \
  Sources/SrtFlow/VideoEditVolumeCurve.swift \
  Sources/SrtFlow/VideoEditFilterModels.swift \
  Sources/SrtFlow/VideoEditFilterLUT.swift \
  Sources/SrtFlow/VideoEditClipVisibility.swift \
  Sources/SrtFlow/VideoEditTransitionHandles.swift \
  Sources/SrtFlow/VideoEditFadeWindow.swift \
  Sources/SrtFlow/VideoEditAudioFade.swift \
  Sources/SrtFlow/VideoEditVideoFade.swift \
  Sources/SrtFlow/VideoEditClipAnimation.swift \
  Sources/SrtFlow/VideoEditClipAnimator.swift \
  Sources/SrtFlow/VideoEditTrackPalette.swift \
  Sources/SrtFlow/VideoEditTextStyle.swift \
  Sources/SrtFlow/VideoEditTextEasing.swift \
  Sources/SrtFlow/VideoEditTextAnimation.swift \
  Sources/SrtFlow/VideoEditTextAnimator.swift \
  Sources/SrtFlow/VideoEditTextNumber.swift \
  Sources/SrtFlow/VideoEditTextNumberRenderer.swift \
  Sources/SrtFlow/VideoEditTextModels.swift \
  Sources/SrtFlow/VideoEditTextRows.swift \
  Sources/SrtFlow/VideoEditTextLayout.swift \
  Sources/SrtFlow/VideoEditTextRenderer.swift \
  Sources/SrtFlow/VideoEditTextDrawing.swift \
  Sources/SrtFlow/VideoEditTextExport.swift \
  Sources/SrtFlow/VideoEditClipMarker.swift \
  Sources/SrtFlow/VideoEditAnimation.swift \
  Sources/SrtFlow/VideoEditTimelineEdits.swift \
  Sources/SrtFlow/VideoEditTimelineSnap.swift \
  Sources/SrtFlow/VideoEditExportGraph.swift \
  Sources/SrtFlow/VideoEditExportFilterScript.swift \
  Sources/SrtFlow/VideoEditExportMixdown.swift \
  Sources/SrtFlow/MediaReadQueue.swift \
  Sources/SrtFlow/VideoEditCompositionBuilder.swift \
  Sources/SrtFlow/VideoEditMediaAssetCache.swift \
  Sources/SrtFlow/VideoEditBlackBaseVideo.swift \
  Sources/SrtFlow/VideoEditCompositionAudioTracks.swift \
  Sources/SrtFlow/VideoEditAudioMeter.swift \
  Sources/SrtFlow/VideoEditTimelineRowHeights.swift \
  Sources/SrtFlow/VideoEditPrerender.swift \
  Sources/SrtFlow/BurnInWorkspace.swift \
  Sources/SrtFlow/MediaProbe.swift \
  Sources/SrtFlow/AppLanguage.swift \
  checks/VideoFade/main.swift \
  "$BUILD_DIR"/SrtFlowCore.build/*.o

echo "==> 运行"
SRTFLOW_FFMPEG="${SRTFLOW_FFMPEG:-$(pwd)/vendor/ffmpeg}" "$OUT"
