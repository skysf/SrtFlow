#!/usr/bin/env bash
# 时间线拖动的吸附 / 对齐线 / 主轨插入位置自检：两条边都参与吸附、
# 跟着动的块不许当参考点、指示线和落点是同一个数。
#
# 用法：
#   scripts/check-timeline-snap.sh
#
# 与 check-freeze-frame.sh 同一套编法：被测代码在 SrtFlow app target 里，
# SwiftPM 不允许两个 target 共用源文件，所以单独编成自检二进制来跑。
# 能这么编的前提是吸附全是纯值函数、单独放在
# Sources/SrtFlow/VideoEditTimelineSnap.swift —— 别把它们挪回
# VideoEditProject.swift，那个文件拖着 AppKit/SwiftUI/AVFoundation 整个 App。
set -euo pipefail
cd "$(dirname "$0")/.."

# Rosetta 终端下必须显式指定 arm64，否则会去编 x86_64（见 docs/build/）。
ARCH_FLAG="--arch arm64"
TRIPLE="arm64-apple-macosx15.0"

echo "==> swift build ${ARCH_FLAG}（拿 SrtFlowCore 的模块和目标文件）"
# SwiftPM 的编译诊断走 stdout：静默成功可以，失败必须倾倒完整输出。
BUILD_OUT="$(swift build ${ARCH_FLAG} 2>&1)" || { printf '%s\n' "${BUILD_OUT}"; exit 1; }
BUILD_DIR="$(swift build ${ARCH_FLAG} --show-bin-path)"

OUT="$(mktemp -d)/snapcheck"
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
  Sources/SrtFlow/VideoEditFormatVersion.swift \
  Sources/SrtFlow/MediaProbe.swift \
  Sources/SrtFlow/AppLanguage.swift \
  checks/TimelineSnap/main.swift \
  "$BUILD_DIR"/SrtFlowCore.build/*.o

echo "==> 运行"
"$OUT"
