#!/usr/bin/env bash
# TranslationPreflight（翻译配对预检）的自检。
#
# 用法：
#   scripts/check-translation-preflight.sh
#
# 与 check-player-clock.sh 同一套编法：被测代码在 SrtFlow app target 里，
# 单独编成自检二进制来跑。同语种判据本体在 SrtFlowCore
#（`SubtitleLanguageDetection.languageKey` —— 检测的候选去重用同一份），
# 所以要先 swift build 把 Core 的模块和目标文件拿过来。
set -euo pipefail
cd "$(dirname "$0")/.."

# Rosetta 终端下必须显式指定 arm64（见 docs/build/）。
TRIPLE="arm64-apple-macosx15.0"

ARCH_FLAG="--arch arm64"
echo "==> swift build ${ARCH_FLAG}（拿 SrtFlowCore 的模块和目标文件）"
# SwiftPM 的编译诊断走 stdout：静默成功可以，失败必须倾倒完整输出。
BUILD_OUT="$(swift build ${ARCH_FLAG} 2>&1)" || { printf '%s\n' "${BUILD_OUT}"; exit 1; }
BUILD_DIR="$(swift build ${ARCH_FLAG} --show-bin-path)"

OUT="$(mktemp -d)/preflightcheck"
trap 'rm -rf "$(dirname "$OUT")"' EXIT

echo "==> 编译自检二进制"
xcrun swiftc \
  -target "$TRIPLE" \
  -I "$BUILD_DIR/Modules" \
  -o "$OUT" \
  Sources/SrtFlow/SubtitleGen/TranslationPreflight.swift \
  checks/TranslationPreflight/main.swift \
  "$BUILD_DIR"/SrtFlowCore.build/*.o

echo "==> 运行"
"$OUT"
