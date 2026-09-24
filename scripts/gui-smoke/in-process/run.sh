#!/usr/bin/env bash
# 进程内冒烟：起一个 SrtFlowDev.app，按脚本在它**自己的窗口里**点 / 拖 / 滚 / 按键，
# 不动真鼠标、不抢前台 —— 人正在用这台机器时也能跑（原理见 Sources/SrtFlow/SmokeDriver.swift，
# 步骤表的格式见 Sources/SrtFlow/SmokeScript.swift，流程见 docs/testing/gui-smoke-testing.md
# 「四之六」）。
#
# 用法：
#   scripts/gui-smoke/in-process/run.sh <脚本.json> [工程.srtflowproj]
#
#   工程**会被自动保存改写** —— 传一份拷贝，别传用户的原件。
#   结果：<脚本名>.out.json（和脚本同目录）；脚本里 snapshot 要的截图也落在那个目录。
#   SKIP_BUILD=1：跳过 swift build（刚编过时省半分钟）。
set -euo pipefail
cd "$(dirname "$0")/../../.."
REPO="$(pwd)"

if [ $# -lt 1 ] || [ ! -f "$1" ]; then
  echo "✗ 用法：$0 <脚本.json> [工程.srtflowproj]" >&2
  exit 2
fi
SCRIPT="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
PROJECT=""
if [ $# -ge 2 ]; then PROJECT="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"; fi
OUT_DIR="$(dirname "${SCRIPT}")"
OUT="${OUT_DIR}/$(basename "${SCRIPT}" .json).out.json"
LOG="${OUT_DIR}/$(basename "${SCRIPT}" .json).log"

# ---- 1. 编译（Rosetta 终端下必须显式 arm64，见 docs/build/build-and-packaging.md）----
if [ -z "${SKIP_BUILD:-}" ]; then
  echo "==> swift build --arch arm64"
  BUILD_OUT="$(swift build --arch arm64 2>&1)" || { printf '%s\n' "${BUILD_OUT}"; exit 1; }
fi
BIN_DIR="$(swift build --arch arm64 --show-bin-path)"

# ---- 2. 组装 SrtFlowDev.app：改名、换 bundle id，避开常开着的正式版 ----
APP="${OUT_DIR}/SrtFlowDev.app"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN_DIR}/SrtFlow" "${APP}/Contents/MacOS/SrtFlowDev"
cp -R "${BIN_DIR}/SrtFlow_SrtFlow.bundle" "${APP}/Contents/Resources/"
cp -R "${BIN_DIR}/SrtFlow_SrtFlow.bundle" "${APP}/Contents/MacOS/"
cp packaging/Info.plist "${APP}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable SrtFlowDev" "${APP}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName SrtFlowDev" "${APP}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.srtflow.SrtFlowDev" "${APP}/Contents/Info.plist"
# 两份资源包不加 --deep 会报 "In subcomponent"（gui-smoke-testing.md 第一节）。
codesign --force --deep --sign - "${APP}" >/dev/null 2>&1

# ---- 3. 后台起进程（-g：不抢前台；环境变量用 --env 带进去）----
rm -f "${OUT_DIR}"/*.request "${OUT}" "${LOG}"
OPEN_ARGS=(-g -n
  --env "SRTFLOW_SMOKE_SCRIPT=${SCRIPT}"
  --env "SRTFLOW_SMOKE_OUT=${OUT}"
  --env "SRTFLOW_SMOKE_MUTE=1"
  --env "SRTFLOW_FFMPEG=${REPO}/vendor/ffmpeg"
  --stderr "${LOG}")
if [ -n "${PROJECT}" ]; then OPEN_ARGS+=(--env "SRTFLOW_SMOKE_PROJECT=${PROJECT}"); fi
echo "==> 起 SrtFlowDev（后台，不抢前台）"
open "${OPEN_ARGS[@]}" -a "${APP}" --args -mainWindowSection videoEdit

PID=""
for _ in $(seq 1 100); do
  PID="$(pgrep -n -f "${APP}/Contents/MacOS/SrtFlowDev" || true)"
  [ -n "${PID}" ] && break
  sleep 0.1
done
if [ -z "${PID}" ]; then
  echo "✗ SrtFlowDev 没起来，看 ${LOG}" >&2
  exit 1
fi

# ---- 4. 替它拍截图：App 写 <名字>.request（内容是窗口号），这边拍 <名字>.png ----
DEADLINE=$(( $(date +%s) + 900 ))
while kill -0 "${PID}" 2>/dev/null; do
  for request in "${OUT_DIR}"/*.request; do
    [ -e "${request}" ] || continue
    WINDOW="$(cat "${request}")"
    NAME="$(basename "${request}" .request)"
    screencapture -l "${WINDOW}" -o -x "${OUT_DIR}/${NAME}.png" || echo "⚠️  截图 ${NAME} 失败（锁屏？）" >&2
    rm -f "${request}"
  done
  if [ "$(date +%s)" -gt "${DEADLINE}" ]; then
    echo "✗ 900 秒还没跑完，杀掉" >&2
    kill "${PID}" 2>/dev/null || true
    exit 1
  fi
  sleep 0.1
done

# ---- 5. 结果 ----
if [ ! -f "${OUT}" ]; then
  echo "✗ 没有结果文件，看日志：${LOG}" >&2
  tail -20 "${LOG}" >&2 || true
  exit 1
fi
if grep -c '"error"' "${OUT}" >/dev/null; then
  echo "✗ 脚本出错：" >&2
  grep '"error"' "${OUT}" >&2 || true
  exit 1
fi
echo "✓ 跑完：${OUT}"
