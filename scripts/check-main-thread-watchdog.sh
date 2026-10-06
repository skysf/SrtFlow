#!/usr/bin/env bash
# 主线程心跳看门狗的自检：主线程没卡不许误报；卡过阈值记一次（时长、context、栈里有卡住的函数）；
# 日志文件里有同样的内容；stop 之后不再记；挂起主线程期间抓栈线程不许分配 / 释放内存（第 6 组）、主线程不停
# 分配内存时连续抓栈不许卡死（第 7 组）—— 约束见 docs/architecture/main-thread-stack-capture.md。
# 合同见 docs/testing/main-thread-stalls.md。
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
  checks/MainThreadWatchdog/main.swift \
  checks/MainThreadWatchdog/NoAllocationWhileSuspended.swift \
  checks/MainThreadWatchdog/CaptureUnderMallocChurn.swift

# 第 7 组卡死时，自检进程里判卡死的线程会自己报红退出；这里再兜一道：2 分钟还没跑完就杀掉、判红，
# 免得 CI 一直挂到作业超时。
echo "==> 运行"
"$OUT" &
PID=$!
(
  waited=0
  while kill -0 "${PID}" 2>/dev/null; do
    if [ "${waited}" -ge 120 ]; then
      kill -9 "${PID}" 2>/dev/null || true
      echo "✗ main-thread-watchdog：自检 2 分钟还没跑完，判卡死" >&2
      exit 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
) &
GUARD=$!
STATUS=0
wait "${PID}" || STATUS=$?
wait "${GUARD}" 2>/dev/null || true
exit "${STATUS}"
