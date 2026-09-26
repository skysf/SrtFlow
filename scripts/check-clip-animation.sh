#!/usr/bin/env bash
# **入场 / 出场动画的两条管线对账**。
#
# 同一份时间线跑两遍：一遍建 AVComposition 真取帧（预览走的那条），一遍调
# `VideoEditExportGraph.plan()` 真跑 ffmpeg 出成片再抽帧（导出走的那条），
# 同一个时刻、同一块区域，两边的数必须对得上。
#
# 为什么必须这么测：逐帧效果的成片是**预渲染**出来的（AnimatedClipPrerenderer
# 用预览同一套合成渲中间片），"按构造一致"只是设计意图 —— 中间接了预渲染、
# ProRes 转码、alphamerge、overlay 一整条 ffmpeg 链，任何一环错位都会让
# 「预览看着对、成片不对」。这条检查就是那份构造一致性的机器证明。
#
# 守的契约（改 ClipAnimator / CompositionBuilder / ExportGraph 之前必读，
# 长期约束见 docs/architecture/clip-animation.md）：
#   1. 五种效果在两条管线里逐点同账；
#   2. 纯 Fade **不预渲染**（走 ffmpeg 的 fade 快路径），导出不因此变慢；
#   3. 铺满画布的段做位移/缩放时两条管线都不许露出底下那一层。
#
# 用法：
#   scripts/check-clip-animation.sh
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

OUT="$(mktemp -d)/clipanimation"
trap 'rm -rf "$(dirname "$OUT")"' EXIT

echo "==> 编译自检二进制"
xcrun swiftc \
  -target "$TRIPLE" \
  -wmo \
  -I "$BUILD_DIR/Modules" \
  -o "$OUT" \
  Sources/SrtFlow/VideoEditModels.swift \
  Sources/SrtFlow/VideoEditClipCrop.swift \
  Sources/SrtFlow/VideoEditShapeModels.swift \
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
  Sources/SrtFlow/VideoEditTextOdometer.swift \
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
  Sources/SrtFlow/VideoEditSubtitleDocuments.swift \
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
  checks/ClipAnimation/main.swift \
  "$BUILD_DIR"/SrtFlowCore.build/*.o

echo "==> 运行"
SRTFLOW_FFMPEG="${SRTFLOW_FFMPEG:-$(pwd)/vendor/ffmpeg}" "$OUT"
