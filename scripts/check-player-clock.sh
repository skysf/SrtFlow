#!/usr/bin/env bash
# PlayerClock 悬停预览（peek/endPeek/displayTime）状态机的自检，
# 以及播放头的慢读法（PacedPlayhead：播放中不跟、停下追上一次），
# 和卸片之后晚到的时间回调不许把播放头写回去（真播放器 + ffmpeg 现做的小视频）。
#
# 用法：
#   scripts/check-player-clock.sh
#
# 与 check-project-file.sh 同一套编法：被测代码在 SrtFlow app target 里，
# SwiftPM 不允许两个 target 共用源文件，所以单独编成自检二进制来跑。
set -euo pipefail
cd "$(dirname "$0")/.."

# Rosetta 终端下必须显式指定 arm64，否则会去编 x86_64（见 docs/build/）。
ARCH_FLAG="--arch arm64"
TRIPLE="arm64-apple-macosx15.0"

echo "==> swift build ${ARCH_FLAG} --target SrtFlowCore（拿 SrtFlowCore 的模块和目标文件）"
# SwiftPM 的编译诊断走 stdout：静默成功可以，失败必须倾倒完整输出
#（>/dev/null 会把编译错误吞成无字天书，见 docs/bugfixes/ 2026-08-08 CI 首跑案例）。
BUILD_OUT="$(swift build ${ARCH_FLAG} --target SrtFlowCore 2>&1)" || { printf '%s\n' "${BUILD_OUT}"; exit 1; }
BUILD_DIR="$(swift build ${ARCH_FLAG} --show-bin-path)"

OUT="$(mktemp -d)/clockcheck"
trap 'rm -rf "$(dirname "$OUT")"' EXIT

echo "==> 编译自检二进制"
xcrun swiftc \
  -target "$TRIPLE" \
  -wmo \
  -I "$BUILD_DIR/Modules" \
  -o "$OUT" \
  Sources/SrtFlow/VideoPreviewView.swift \
  Sources/SrtFlow/PacedPlayhead.swift \
  Sources/SrtFlow/AudioEngine/PlaybackAudioSource.swift \
  Sources/SrtFlow/PerfCounters.swift \
  checks/PlayerClock/main.swift \
  checks/PlayerClock/PacedPlayheadChecks.swift \
  checks/PlayerClock/GoToStartChecks.swift \
  checks/PlayerClock/DetachChecks.swift \
  "$BUILD_DIR"/SrtFlowCore.build/*.o

# 卸片那一项要真的播放器和素材：现做一段 60 秒带声音的小视频（ffmpeg 同 check-text-render：vendor/ffmpeg 或
# SRTFLOW_FFMPEG）。要带声音：没有音轨时停着卸片不出那一拍晚到的回调，只测得到「在播」那一种。
FFMPEG="${SRTFLOW_FFMPEG:-$(pwd)/vendor/ffmpeg}"
CLIP="$(dirname "$OUT")/clip.mp4"
"$FFMPEG" -hide_banner -loglevel error -y -f lavfi -i testsrc2=s=64x64:r=10:d=60 -f lavfi -i sine=f=440:d=60 \
  -shortest -c:v libx264 -pix_fmt yuv420p -c:a aac "$CLIP"

echo "==> 运行"
"$OUT" "$CLIP"
