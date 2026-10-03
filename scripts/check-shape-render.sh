#!/usr/bin/env bash
# **形状的真实回归**：预览画的和成片一样，入场 / 出场动画落在对的帧上（2026-10-03，docs/architecture/shapes.md）。
#
# 守两条契约（改 ShapeOutline / ShapePreviewDrawing / ShapePNGRenderer / ShapeOverlayExport 之前必读）：
#   1. 预览那个画法（ShapePreviewDrawing，离屏渲一张）和导出那张（ShapePNGRenderer）逐像素重合：
#      五种形状 × 描边 / 实心 × 不动 / 画到一半 / 擦除 / 缩放 / 半透明（checks/ShapeRender/Parity.swift）；
#   2. 真跑导出抽帧：入场画到一半、中间整个、出场淡到一半、段外没有；只逐帧渲动画那两截（checks/ShapeRender/Export.swift）。
# 纯值的那一半（求值、笔顺、存盘、v31）在 scripts/check-project-file.sh 第 44 组。
#
# 用法：
#   scripts/check-shape-render.sh
#
# 需要 ffmpeg（导出那一半）；素材是 AVAssetWriter 现写的黑底视频。
set -euo pipefail
cd "$(dirname "$0")/.."

# Rosetta 终端下必须显式指定 arm64，否则会去编 x86_64（见 docs/build/）。
ARCH_FLAG="--arch arm64"
TRIPLE="arm64-apple-macosx15.0"

echo "==> swift build ${ARCH_FLAG} --target SrtFlowCore"
# SwiftPM 的编译诊断走 stdout：静默成功可以，失败必须倾倒完整输出。
BUILD_OUT="$(swift build ${ARCH_FLAG} --target SrtFlowCore 2>&1)" || { printf '%s\n' "${BUILD_OUT}"; exit 1; }
BUILD_DIR="$(swift build ${ARCH_FLAG} --show-bin-path)"

OUT="$(mktemp -d)/shaperender"
trap 'rm -rf "$(dirname "$OUT")"' EXIT

echo "==> 编译自检二进制"
xcrun swiftc \
  -target "$TRIPLE" \
  -wmo \
  -I "$BUILD_DIR/Modules" \
  -o "$OUT" \
  Sources/SrtFlow/VideoEditModels.swift \
  Sources/SrtFlow/VideoEditCanvasRatio.swift \
  Sources/SrtFlow/StillAlphaNaming.swift \
  Sources/SrtFlow/VideoEditMediaReferences.swift \
  Sources/SrtFlow/VideoEditClipUpscale.swift \
  Sources/SrtFlow/VideoEditClipUpscaleRecord.swift \
  Sources/SrtFlow/VideoEditTrackSlot.swift \
  Sources/SrtFlow/VideoEditClipCrop.swift \
  Sources/SrtFlow/VideoEditShapeModels.swift \
  Sources/SrtFlow/VideoEditShapeAnimation.swift \
  Sources/SrtFlow/VideoEditSoundSceneRecipe.swift \
  Sources/SrtFlow/VideoEditSoundSceneDSP.swift \
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
  Sources/SrtFlow/VideoEditTextLayoutFonts.swift \
  Sources/SrtFlow/VideoEditTextRenderer.swift \
  Sources/SrtFlow/VideoEditTextHitGeometry.swift \
  Sources/SrtFlow/VideoEditTextDrawing.swift \
  Sources/SrtFlow/VideoEditTextExport.swift \
  Sources/SrtFlow/VideoEditOverlayExportFile.swift \
  Sources/SrtFlow/VideoEditClipMarker.swift \
  Sources/SrtFlow/VideoEditAnimation.swift \
  Sources/SrtFlow/VideoEditKeyframeEasing.swift \
  Sources/SrtFlow/VideoEditTimelineEdits.swift \
  Sources/SrtFlow/FreezeSliver.swift \
  Sources/SrtFlow/VideoEditSubtitleDocuments.swift \
  Sources/SrtFlow/VideoEditTimelineLinkage.swift \
  Sources/SrtFlow/VideoEditTimelineLinkageLanding.swift \
  Sources/SrtFlow/VideoEditTimelineSnap.swift \
  Sources/SrtFlow/VideoEditExportGraph.swift \
  Sources/SrtFlow/VideoEditShapeOverlayExport.swift \
  Sources/SrtFlow/VideoEditExportTransform.swift \
  Sources/SrtFlow/VideoEditExportPlan.swift \
  Sources/SrtFlow/VideoEditGradeExport.swift \
  Sources/SrtFlow/VideoEditCoverExport.swift \
  Sources/SrtFlow/VideoEditShapePNGRenderer.swift \
  Sources/SrtFlow/VideoEditShapeOutline.swift \
  Sources/SrtFlow/VideoEditShapePreviewDrawing.swift \
  Sources/SrtFlow/VideoEditExportFilterScript.swift \
  Sources/SrtFlow/VideoEditExportMixdown.swift \
  Sources/SrtFlow/ExportPeakLimiter.swift \
  Sources/SrtFlow/ExportLoudnessMeter.swift \
  Sources/SrtFlow/AudioKWeighting.swift \
  Sources/SrtFlow/MediaReadQueue.swift \
  Sources/SrtFlow/VideoEditCompositionBuilder.swift \
  Sources/SrtFlow/CompositionClipInsert.swift \
  Sources/SrtFlow/OptimizedMedia/OptimizedMediaLookup.swift \
  Sources/SrtFlow/OptimizedMedia/OptimizedMediaPolicy.swift \
  Sources/SrtFlow/VideoEditKeyframeSlices.swift \
  Sources/SrtFlow/CompositionTime.swift \
  Sources/SrtFlow/CompositionSlices.swift \
  Sources/SrtFlow/CompositionHold.swift \
  Sources/SrtFlow/VideoEditMediaAssetCache.swift \
  Sources/SrtFlow/VideoEditBlackBaseVideo.swift \
  Sources/SrtFlow/VideoEditAudioMeter.swift \
  Sources/SrtFlow/AudioEngine/AudioGainTable.swift \
  Sources/SrtFlow/AudioEngine/MeterSlot.swift \
  Sources/SrtFlow/AudioEngine/AudioEngineConfig.swift \
  Sources/SrtFlow/AudioEngine/AudioRing.swift \
  Sources/SrtFlow/AudioEngine/AudioPublished.swift \
  Sources/SrtFlow/AudioEngine/AudioSegmentReader.swift \
  Sources/SrtFlow/AudioEngine/AudioTimeStretchReader.swift \
  Sources/SrtFlow/AudioEngine/AudioTrackFeeder.swift \
  Sources/SrtFlow/AudioEngine/AudioTrackRenderer.swift \
  Sources/SrtFlow/AudioEngine/TimelineAudioEngine.swift \
  Sources/SrtFlow/AudioEngine/PlaybackAudioSource.swift \
  Sources/SrtFlow/VideoEditTimelineRowHeights.swift \
  Sources/SrtFlow/VideoEditPrerender.swift \
  Sources/SrtFlow/BurnInWorkspace.swift \
  Sources/SrtFlow/SubtitleFontScale.swift \
  Sources/SrtFlow/SubtitleFallbackFont.swift \
  Sources/SrtFlow/MediaProbe.swift \
  Sources/SrtFlow/OptimizedMedia/MediaKeyframeProbe.swift \
  Sources/SrtFlow/AppLanguage.swift \
  checks/ShapeRender/main.swift \
  checks/ShapeRender/Parity.swift \
  checks/ShapeRender/Export.swift \
  "$BUILD_DIR"/SrtFlowCore.build/*.o

echo "==> 运行"
SRTFLOW_FFMPEG="${SRTFLOW_FFMPEG:-$(pwd)/vendor/ffmpeg}" "$OUT"
