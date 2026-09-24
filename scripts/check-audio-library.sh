#!/usr/bin/env bash
# **音频库清单（manifest）的回归**：解析的宽容边界 + 双语搜索。
#
# 为什么这两件事要守卫：manifest 不是打进 App 的资源，而是放在 R2 上的数据 ——
# 它会先于 App 更新，也会后于 App 更新。「什么该忍、什么该拒」一旦错了，表现是
# 「用户的库突然空了」或者「读出一半装作没事」，两种都极难查。
#
# 搜索那一组守的是口径不是实现：**多个词之间是「与」**，而且中英两种语言都要能
# 命中同一个 tag（tag 的双语对照在 manifest 里，不进 Localizable.strings ——
# 理由见 docs/plans/2026-09-22-audio-library.md 第四节第 3 条）。
#
# 用法：
#   scripts/check-audio-library.sh
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

OUT="$(mktemp -d)/audiolibrarycheck"
trap 'rm -rf "$(dirname "$OUT")"' EXIT

echo "==> 编译自检二进制"
# 清单是手抄的（SwiftPM 不允许两个 target 共用源文件，见
# scripts/check-project-file.sh 开头），由 checks/check-script-source-lists.sh 守着。
xcrun swiftc \
  -target "$TRIPLE" \
  -wmo \
  -I "$BUILD_DIR/Modules" \
  -o "$OUT" \
  Sources/SrtFlow/AudioLibraryManifest.swift \
  Sources/SrtFlow/PerfCounters.swift \
  Sources/SrtFlow/AudioLibraryCache.swift \
  Sources/SrtFlow/AppLanguage.swift \
  checks/AudioLibrary/main.swift

echo "==> 跑自检"
"$OUT"
