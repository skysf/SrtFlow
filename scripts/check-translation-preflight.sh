#!/usr/bin/env bash
# TranslationPreflight（翻译配对预检）的自检。
#
# 用法：
#   scripts/check-translation-preflight.sh
#
# 与 check-player-clock.sh 同一套编法：被测代码在 SrtFlow app target 里，
# 单独编成自检二进制来跑。TranslationPreflight 只依赖 Foundation，
# 不需要先 swift build 拿 SrtFlowCore。
set -euo pipefail
cd "$(dirname "$0")/.."

# Rosetta 终端下必须显式指定 arm64（见 docs/build/）。
TRIPLE="arm64-apple-macosx15.0"

OUT="$(mktemp -d)/preflightcheck"
trap 'rm -rf "$(dirname "$OUT")"' EXIT

echo "==> 编译自检二进制"
xcrun swiftc \
  -target "$TRIPLE" \
  -o "$OUT" \
  Sources/SrtFlow/SubtitleGen/TranslationPreflight.swift \
  checks/TranslationPreflight/main.swift

echo "==> 运行"
"$OUT"
