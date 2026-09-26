#!/usr/bin/env bash
# **时间轴滤镜（调色）的回归**：LUT 数学 + 模型规则 + 预览/导出逐像素比对。
#
# 第三组是这条脚本的重点，也是「滤镜」这个功能的验收项：同一个输入色，
# 三方必须对得上 —— 配方算出来的值、CoreImage 渲出来的值、真跑生产
# `VideoEditExportGraph.plan()` 出片后解出来的值。
#
# 为什么非得真跑 ffmpeg：表的排列顺序、查表的色彩空间、`enable` 的时间窗、
# 整条生产滤镜链接不接得上 —— 这些纯值断言一个都摸不到。反向验证做过：把
# .cube 的通道顺序写反，逐像素那几条当场变红（2026-09-21 实测）。
#
# `interp=trilinear` 这一项由**参数断言**守，不是靠像素：冷铁的表在取样点
# 附近是局部线性的，而 tetrahedral 和 trilinear 对线性函数给出同一个值 ——
# 像素比对分辨不了。等第二刀补上带曲线的预设，像素那条才会跟着变敏感。
#
# 用法：
#   scripts/check-filters.sh
set -euo pipefail
cd "$(dirname "$0")/.."

# Rosetta 终端下必须显式指定 arm64（见 docs/build/）。
ARCH_FLAG="--arch arm64"
TRIPLE="arm64-apple-macosx15.0"

echo "==> swift build ${ARCH_FLAG} --target SrtFlowCore"
# SwiftPM 的编译诊断走 stdout：静默成功可以，失败必须倾倒完整输出
#（>/dev/null 会把编译错误吞成无字天书，见 docs/bugfixes/ 2026-08-08 CI 首跑案例）。
BUILD_OUT="$(swift build ${ARCH_FLAG} --target SrtFlowCore 2>&1)" || { printf '%s\n' "${BUILD_OUT}"; exit 1; }
BUILD_DIR="$(swift build ${ARCH_FLAG} --show-bin-path)"

OUT="$(mktemp -d)/filterscheck"
trap 'rm -rf "$(dirname "$OUT")"' EXIT

echo "==> 编译自检二进制"
xcrun swiftc \
  -target "$TRIPLE" \
  -wmo \
  -I "$BUILD_DIR/Modules" \
  -o "$OUT" \
  Sources/SrtFlow/VideoEditModels.swift \
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
  Sources/SrtFlow/VideoEditFilterPayloadTypes.swift \
  Sources/SrtFlow/VideoEditFilterClipboard.swift \
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
  checks/Filters/main.swift \
  "$BUILD_DIR"/SrtFlowCore.build/*.o

echo "==> 运行"
SRTFLOW_FFMPEG="${SRTFLOW_FFMPEG:-$(pwd)/vendor/ffmpeg}" "$OUT"
