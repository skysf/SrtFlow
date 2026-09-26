#!/usr/bin/env bash
# **预览调色的接线回归**：把生产的 `FilterStack` + `FilterStackAttachment` 挂到
# 真的 AVPlayerView 上，拍窗口，数像素。
#
# 和 scripts/check-filters.sh 的分工（别搞混）：
#   - 那个守的是**表**：LUT 数学、.cube 写法、和导出逐像素对齐。它对「这张表有
#     没有真的被挂到播放器上」一无所知 —— 接线断了那边照样全绿。
#   - 本脚本守的就是那一段接线，而且是唯一守它的东西。
#
# **要图形会话，所以故意不在 check-all.sh 里**（无图形会话会假红），
# 同 scripts/check-instant-tooltip-panel.sh。改 VideoEditFilterPreview.swift
# 时按 docs/testing/gui-smoke-testing.md 跑一遍。
#
# 用法：
#   scripts/check-filter-preview-attach.sh
set -euo pipefail
cd "$(dirname "$0")/.."

# Rosetta 终端下必须显式指定 arm64（见 docs/build/）。
ARCH_FLAG="--arch arm64"
TRIPLE="arm64-apple-macosx15.0"

echo "==> swift build ${ARCH_FLAG}"
# SwiftPM 的编译诊断走 stdout：静默成功可以，失败必须倾倒完整输出
#（>/dev/null 会把编译错误吞成无字天书，见 docs/bugfixes/ 2026-08-08 CI 首跑案例）。
BUILD_OUT="$(swift build ${ARCH_FLAG} 2>&1)" || { printf '%s\n' "${BUILD_OUT}"; exit 1; }
BUILD_DIR="$(swift build ${ARCH_FLAG} --show-bin-path)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
OUT="$WORK/attachcheck"

echo "==> 编译自检二进制"
xcrun swiftc \
  -target "$TRIPLE" \
  -I "$BUILD_DIR/Modules" \
  -o "$OUT" \
  Sources/SrtFlow/VideoEditModels.swift \
  Sources/SrtFlow/VideoEditShapeModels.swift \
  Sources/SrtFlow/VideoEditSoundScene.swift \
  Sources/SrtFlow/PerfCounters.swift \
  Sources/SrtFlow/VideoEditVolumeCurve.swift \
  Sources/SrtFlow/VideoEditFilterModels.swift \
  Sources/SrtFlow/VideoEditFilterLUT.swift \
  Sources/SrtFlow/VideoEditFilterPreview.swift \
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
  Sources/SrtFlow/VideoEditSubtitleDocuments.swift \
  Sources/SrtFlow/VideoEditAnimation.swift \
  Sources/SrtFlow/VideoEditClipMarker.swift \
  Sources/SrtFlow/VideoEditTimelineEdits.swift \
  Sources/SrtFlow/VideoEditTimelineRowSelection.swift \
  Sources/SrtFlow/VideoEditTimelineSnap.swift \
  Sources/SrtFlow/MediaProbe.swift \
  Sources/SrtFlow/AppLanguage.swift \
  checks/FilterPreviewAttach/main.swift \
  "$BUILD_DIR"/SrtFlowCore.build/*.o

# 纯色素材：颜色是平的，取哪一点都一样，像素断言不受构图影响。
FFMPEG_BIN="${SRTFLOW_FFMPEG:-$(pwd)/vendor/ffmpeg}"
if [ ! -x "${FFMPEG_BIN}" ]; then
  echo "✗ 找不到可执行的 ffmpeg：${FFMPEG_BIN}" >&2
  exit 1
fi
echo "==> 现造纯色素材"
"${FFMPEG_BIN}" -y -hide_banner -loglevel error \
  -f lavfi -i "color=c=0xB45A3C:size=320x180:rate=30:duration=30" \
  -c:v libx264 -pix_fmt yuv420p "$WORK/flat.mp4"

mkfifo "$WORK/out.fifo" "$WORK/ctl.fifo"

echo "==> 运行（会短暂弹出一个窗口）"
"$OUT" "$WORK/flat.mp4" "$WORK/out.fifo" "$WORK/ctl.fifo" "$WORK" &
PROBE_PID=$!

# 两次换手：每次拿窗口号 → 按窗口号截图（无视遮挡）→ 放行。
for step in 1 2; do
  WINDOW_ID="$(cat "$WORK/out.fifo")"
  /usr/sbin/screencapture -l "$WINDOW_ID" -x -o "$WORK/shot${step}.png"
  echo "go" > "$WORK/ctl.fifo"
done

wait "$PROBE_PID"
