#!/usr/bin/env bash
# **预览上的盖一块（模糊 / 马赛克）的接线回归**：把生产的 `CoverHostView`（同一个播放器再开一层）+ `CoverStack` +
# `FilterStackAttachment` 放进真的窗口，拍屏，数像素（checks/CoverPreviewAttach/）。
#
# 和 scripts/check-cover-export.sh 的分工（别搞混）：那个守的是**成片**；预览这一层是 CALayer + 图层滤镜，纯值的自检对
# 「这一层有没有真的挂上、盖在哪、蒙没蒙对」一无所知，接线断了它照样全绿 —— 本脚本守的就是这一段，而且是唯一守它的东西。
# 量的是次序和位置（不比绝对色值，截图会过显示色彩管理）：块里被糊成混色、块外还是硬的、改动的行正好是块的上下沿、
# 调色带上了、马赛克的格子从块的左上角起算、两块同时盖、撤掉之后回到参照。
#
# **要图形会话，所以故意不在 check-all.sh 里**（无图形会话会假红），同 scripts/check-filter-preview-attach.sh。
# 改 VideoEditCoverPreview.swift / VideoEditCoverFilters.swift 时按 docs/testing/gui-smoke-testing.md 跑一遍。
# 长期约束见 docs/architecture/cover-blur-mosaic.md。
#
# 用法：
#   scripts/check-cover-preview-attach.sh
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
OUT="$WORK/coverattach"

echo "==> 编译自检二进制"
xcrun swiftc \
  -target "$TRIPLE" \
  -I "$BUILD_DIR/Modules" \
  -o "$OUT" \
  Sources/SrtFlow/VideoEditModels.swift \
  Sources/SrtFlow/VideoEditCanvasRatio.swift \
  Sources/SrtFlow/VideoEditMediaReferences.swift \
  Sources/SrtFlow/VideoEditClipUpscale.swift \
  Sources/SrtFlow/VideoEditClipUpscaleRecord.swift \
  Sources/SrtFlow/VideoEditTrackSlot.swift \
  Sources/SrtFlow/VideoEditClipCrop.swift \
  Sources/SrtFlow/VideoEditShapeModels.swift \
  Sources/SrtFlow/VideoEditSoundScene.swift \
  Sources/SrtFlow/PerfCounters.swift \
  Sources/SrtFlow/VideoEditVolumeCurve.swift \
  Sources/SrtFlow/VideoEditFilterModels.swift \
  Sources/SrtFlow/VideoEditFilterLUT.swift \
  Sources/SrtFlow/VideoEditFilterPreview.swift \
  Sources/SrtFlow/PlayerLayerView.swift \
  Sources/SrtFlow/VideoEditCoverFilters.swift \
  Sources/SrtFlow/VideoEditCoverPreview.swift \
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
  Sources/SrtFlow/VideoEditSubtitleDocuments.swift \
  Sources/SrtFlow/VideoEditAnimation.swift \
  Sources/SrtFlow/VideoEditKeyframeEasing.swift \
  Sources/SrtFlow/VideoEditClipMarker.swift \
  Sources/SrtFlow/VideoEditTimelineEdits.swift \
  Sources/SrtFlow/FreezeSliver.swift \
  Sources/SrtFlow/VideoEditTimelineRowSelection.swift \
  Sources/SrtFlow/VideoEditTimelineLinkage.swift \
  Sources/SrtFlow/VideoEditTimelineLinkageLanding.swift \
  Sources/SrtFlow/VideoEditTimelineSnap.swift \
  Sources/SrtFlow/MediaProbe.swift \
  Sources/SrtFlow/OptimizedMedia/MediaKeyframeProbe.swift \
  Sources/SrtFlow/MediaReadQueue.swift \
  Sources/SrtFlow/AppLanguage.swift \
  checks/CoverPreviewAttach/main.swift \
  checks/CoverPreviewAttach/Assertions.swift \
  "$BUILD_DIR"/SrtFlowCore.build/*.o

# 素材：左红右蓝（交界在正中）、横向 / 纵向的亮度渐变（量马赛克的格线）。
FFMPEG_BIN="${SRTFLOW_FFMPEG:-$(pwd)/vendor/ffmpeg}"
if [ ! -x "${FFMPEG_BIN}" ]; then
  echo "✗ 找不到可执行的 ffmpeg：${FFMPEG_BIN}" >&2
  exit 1
fi
echo "==> 现造素材"
"${FFMPEG_BIN}" -y -hide_banner -loglevel error \
  -f lavfi -i "color=c=0xE01010:s=160x180:r=30:d=30" -f lavfi -i "color=c=0x1010E0:s=160x180:r=30:d=30" \
  -filter_complex "[0][1]hstack" -c:v libx264 -crf 8 -pix_fmt yuv420p "$WORK/redblue.mp4"
"${FFMPEG_BIN}" -y -hide_banner -loglevel error \
  -f lavfi -i "nullsrc=s=320x180:r=30:d=30,geq=lum='16+219*X/320':cb=128:cr=128" -c:v libx264 -crf 6 -pix_fmt yuv420p "$WORK/hramp.mp4"
"${FFMPEG_BIN}" -y -hide_banner -loglevel error \
  -f lavfi -i "nullsrc=s=320x180:r=30:d=30,geq=lum='16+219*Y/180':cb=128:cr=128" -c:v libx264 -crf 6 -pix_fmt yuv420p "$WORK/vramp.mp4"

mkfifo "$WORK/out.fifo" "$WORK/ctl.fifo"

echo "==> 运行（会短暂弹出一个窗口）"
"$OUT" "$WORK/redblue.mp4" "$WORK/hramp.mp4" "$WORK/vramp.mp4" "$WORK/out.fifo" "$WORK/ctl.fifo" "$WORK" &
PROBE_PID=$!

# 看门狗：自检程序一开口就退出（参数不对、没有图形会话）时，下面 `cat` 在 FIFO 上永远等不到写的人 —— 90 秒没走完就杀掉它们。
( sleep 90; kill "$PROBE_PID" 2>/dev/null; pkill -f "cat ${WORK}/out.fifo" 2>/dev/null ) &
WATCHDOG=$!

# 两次换手：每次拿窗口号 → 按窗口号截图（无视遮挡）→ 放行。
for step in 1 2; do
  WINDOW_ID="$(cat "$WORK/out.fifo")"
  /usr/sbin/screencapture -l "$WINDOW_ID" -x -o "$WORK/shot${step}.png"
  echo "go" > "$WORK/ctl.fifo"
done

wait "$PROBE_PID"
STATUS=$?
kill "$WATCHDOG" 2>/dev/null || true
exit "$STATUS"
