#!/usr/bin/env bash
# **音频引擎的等价自检**：同一条时间线，AVFoundation 那份混音（今天的预览和成片）和引擎离线渲染出来的声音
# 逐 10 ms 窗口比 RMS（差 ≤ 0.15 dB；重采样的素材 0.3 dB），一边有声一边静音算错，引擎不许欠载。
# 素材是现造的恒定振幅正弦（和 check-audio-fade 同一套，需要 ffmpeg）。
#
# 用法：
#   scripts/check-audio-engine.sh
#
# 与 check-audio-fade.sh 同一套编法（源文件清单从它复制，再加 AudioEngine/ 下的文件）：被测代码在 SrtFlow
# app target 里，SwiftPM 不允许两个 target 共用源文件，所以单独编成自检二进制来跑。
# 方案：docs/plans/2026-10-01-audio-engine.md。
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

OUT="$(mktemp -d)/audioengine"
trap 'rm -rf "$(dirname "$OUT")"' EXIT

echo "==> 编译自检二进制"
xcrun swiftc \
  -target "$TRIPLE" \
  -wmo \
  -I "$BUILD_DIR/Modules" \
  -o "$OUT" \
  Sources/SrtFlow/VideoEditModels.swift \
  Sources/SrtFlow/VideoEditTrackSlot.swift \
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
  Sources/SrtFlow/VideoEditTextLayoutFonts.swift \
  Sources/SrtFlow/VideoEditTextRenderer.swift \
  Sources/SrtFlow/VideoEditTextDrawing.swift \
  Sources/SrtFlow/VideoEditTextExport.swift \
  Sources/SrtFlow/VideoEditClipMarker.swift \
  Sources/SrtFlow/VideoEditAnimation.swift \
  Sources/SrtFlow/VideoEditKeyframeEasing.swift \
  Sources/SrtFlow/VideoEditTimelineEdits.swift \
  Sources/SrtFlow/FreezeSliver.swift \
  Sources/SrtFlow/VideoEditSubtitleDocuments.swift \
  Sources/SrtFlow/VideoEditTimelineSnap.swift \
  Sources/SrtFlow/VideoEditExportGraph.swift \
  Sources/SrtFlow/VideoEditExportPlan.swift \
  Sources/SrtFlow/VideoEditGradeExport.swift \
  Sources/SrtFlow/VideoEditCoverExport.swift \
  Sources/SrtFlow/VideoEditShapePNGRenderer.swift \
  Sources/SrtFlow/VideoEditExportFilterScript.swift \
  Sources/SrtFlow/VideoEditExportMixdown.swift \
  Sources/SrtFlow/ExportPeakLimiter.swift \
  Sources/SrtFlow/ExportLoudnessMeter.swift \
  Sources/SrtFlow/AudioKWeighting.swift \
  Sources/SrtFlow/MediaReadQueue.swift \
  Sources/SrtFlow/VideoEditCompositionBuilder.swift \
  Sources/SrtFlow/VideoEditKeyframeSlices.swift \
  Sources/SrtFlow/CompositionTime.swift \
  Sources/SrtFlow/CompositionSlices.swift \
  Sources/SrtFlow/CompositionHold.swift \
  Sources/SrtFlow/VideoEditMediaAssetCache.swift \
  Sources/SrtFlow/VideoEditBlackBaseVideo.swift \
  Sources/SrtFlow/VideoEditCompositionAudioTracks.swift \
  Sources/SrtFlow/VideoEditAudioMeter.swift \
  Sources/SrtFlow/VideoEditMeterRing.swift \
  Sources/SrtFlow/VideoEditTimelineRowHeights.swift \
  Sources/SrtFlow/VideoEditPrerender.swift \
  Sources/SrtFlow/BurnInWorkspace.swift \
  Sources/SrtFlow/SubtitleFontScale.swift \
  Sources/SrtFlow/SubtitleFallbackFont.swift \
  Sources/SrtFlow/MediaProbe.swift \
  Sources/SrtFlow/AppLanguage.swift \
  Sources/SrtFlow/AudioEngine/AudioEngineConfig.swift \
  Sources/SrtFlow/AudioEngine/AudioRing.swift \
  Sources/SrtFlow/AudioEngine/AudioPublished.swift \
  Sources/SrtFlow/AudioEngine/AudioSegmentReader.swift \
  Sources/SrtFlow/AudioEngine/AudioTrackFeeder.swift \
  Sources/SrtFlow/AudioEngine/AudioTrackRenderer.swift \
  Sources/SrtFlow/AudioEngine/TimelineAudioEngine.swift \
  Sources/SrtFlow/AudioEngine/PlaybackAudioSource.swift \
  Sources/SrtFlow/AudioEngine/AudioEngineFlag.swift \
  checks/AudioEngine/main.swift \
  checks/AudioEngine/Compare.swift \
  checks/AudioEngine/Timelines.swift \
  "$BUILD_DIR"/SrtFlowCore.build/*.o

echo "==> 运行"
SRTFLOW_FFMPEG="${SRTFLOW_FFMPEG:-$(pwd)/vendor/ffmpeg}" "$OUT"
