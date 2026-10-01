#!/usr/bin/env bash
# 主线程心跳看门狗的自检：主线程没卡不许误报；卡过阈值记一次（时长、context、栈里有卡住的函数）；
# 日志文件里有同样的内容；stop 之后不再记。合同见 docs/testing/main-thread-stalls.md。
#
# 用法：
#   scripts/check-main-thread-watchdog.sh
#
# 与 check-timeline-zoom.sh 同一套编法：被测代码在 SrtFlow app target 里，SwiftPM 不允许两个
# target 共用源文件，所以单独编成自检二进制来跑。这两个文件只 import Foundation / Darwin / os，
# 不拖工程和界面。
set -euo pipefail
cd "$(dirname "$0")/.."

# Rosetta 终端下必须显式指定 arm64，否则会去编 x86_64（见 docs/build/）。
TRIPLE="arm64-apple-macosx15.0"

OUT="$(mktemp -d)/watchdogcheck"
trap 'rm -rf "$(dirname "$OUT")"' EXIT

echo "==> 编译自检二进制"
xcrun swiftc \
  -target "$TRIPLE" \
  -wmo \
  -o "$OUT" \
  Sources/SrtFlow/MainThreadStackCapture.swift \
  Sources/SrtFlow/MainThreadWatchdog.swift \
  checks/MainThreadWatchdog/main.swift

echo "==> 运行"
"$OUT"
