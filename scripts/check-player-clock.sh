#!/usr/bin/env bash
# PlayerClock 悬停预览（peek/endPeek/displayTime）状态机的自检。
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

echo "==> swift build ${ARCH_FLAG}（拿 SrtFlowCore 的模块和目标文件）"
swift build ${ARCH_FLAG} >/dev/null
BUILD_DIR="$(swift build ${ARCH_FLAG} --show-bin-path)"

OUT="$(mktemp -d)/clockcheck"
trap 'rm -rf "$(dirname "$OUT")"' EXIT

echo "==> 编译自检二进制"
xcrun swiftc \
  -target "$TRIPLE" \
  -I "$BUILD_DIR/Modules" \
  -o "$OUT" \
  Sources/SrtFlow/VideoPreviewView.swift \
  checks/PlayerClock/main.swift \
  "$BUILD_DIR"/SrtFlowCore.build/*.o

echo "==> 运行"
"$OUT"
