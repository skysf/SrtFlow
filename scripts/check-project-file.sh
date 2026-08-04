#!/usr/bin/env bash
# 工程文件（.srtflowproj）存盘与素材重链接的自检。
#
# 用法：
#   scripts/check-project-file.sh
#
# 为什么是个脚本而不是 SwiftPM 的 target：
#   被测的代码（VideoEditProjectFile / VideoEditModels）在 SrtFlow 这个 app
#   target 里，SwiftPM 不允许两个 target 共用同一批源文件，所以这里直接把需要
#   的几个文件和 checks/ProjectFile/main.swift 编成一个独立二进制来跑。
#   核心库（SrtFlowCore）那部分的自检在 `swift run SrtFlowCoreChecks`。
set -euo pipefail
cd "$(dirname "$0")/.."

# Rosetta 终端下必须显式指定 arm64，否则会去编 x86_64（见 docs/build/）。
ARCH_FLAG="--arch arm64"
TRIPLE="arm64-apple-macosx14.0"

echo "==> swift build ${ARCH_FLAG}（拿 SrtFlowCore 的模块和目标文件）"
swift build ${ARCH_FLAG} >/dev/null
BUILD_DIR="$(swift build ${ARCH_FLAG} --show-bin-path)"

OUT="$(mktemp -d)/projcheck"
trap 'rm -rf "$(dirname "$OUT")"' EXIT

echo "==> 编译自检二进制"
xcrun swiftc \
  -target "$TRIPLE" \
  -I "$BUILD_DIR/Modules" \
  -o "$OUT" \
  Sources/SrtFlow/VideoEditModels.swift \
  Sources/SrtFlow/VideoEditProjectFile.swift \
  Sources/SrtFlow/MediaProbe.swift \
  Sources/SrtFlow/StillImageClipFactory.swift \
  Sources/SrtFlow/AppLanguage.swift \
  checks/ProjectFile/main.swift \
  "$BUILD_DIR"/SrtFlowCore.build/*.o

echo "==> 运行"
"$OUT"
