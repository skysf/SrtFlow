#!/usr/bin/env bash
# 定格（Freeze Frame）时间线变换的自检：分割 + 同轨让位 + 音轨波纹 +
# 叠化区判定 + 关键帧烘焙。
#
# 用法：
#   scripts/check-freeze-frame.sh
#
# 与 check-project-file.sh 同一套编法：被测代码在 SrtFlow app target 里，
# SwiftPM 不允许两个 target 共用源文件，所以单独编成自检二进制来跑。
# 能这么编的前提是定格的状态变换都是纯值函数、单独放在
# Sources/SrtFlow/VideoEditTimelineEdits.swift —— 别把它们挪回
# VideoEditProject.swift，那个文件拖着 AppKit/SwiftUI/AVFoundation 整个 App。
set -euo pipefail
cd "$(dirname "$0")/.."

# Rosetta 终端下必须显式指定 arm64，否则会去编 x86_64（见 docs/build/）。
ARCH_FLAG="--arch arm64"
TRIPLE="arm64-apple-macosx15.0"

echo "==> swift build ${ARCH_FLAG}（拿 SrtFlowCore 的模块和目标文件）"
swift build ${ARCH_FLAG} >/dev/null
BUILD_DIR="$(swift build ${ARCH_FLAG} --show-bin-path)"

OUT="$(mktemp -d)/freezecheck"
trap 'rm -rf "$(dirname "$OUT")"' EXIT

echo "==> 编译自检二进制"
xcrun swiftc \
  -target "$TRIPLE" \
  -I "$BUILD_DIR/Modules" \
  -o "$OUT" \
  Sources/SrtFlow/VideoEditModels.swift \
  Sources/SrtFlow/VideoEditAnimation.swift \
  Sources/SrtFlow/VideoEditTimelineEdits.swift \
  Sources/SrtFlow/VideoEditFormatVersion.swift \
  Sources/SrtFlow/MediaProbe.swift \
  Sources/SrtFlow/AppLanguage.swift \
  checks/FreezeFrame/main.swift \
  "$BUILD_DIR"/SrtFlowCore.build/*.o

echo "==> 运行"
"$OUT"
