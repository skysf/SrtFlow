#!/usr/bin/env bash
# **提示面板落点的真实回归**。
#
# 拿真实的 `InstantTooltipController.show(label:shortcut:from:)`（生产路径本身）
# 对一个已知位置的锚点弹提示，量面板真实落在哪 —— 重点是**摆好之后跑一轮排版，
# 面板不许自己改尺寸或挪位置**。
#
# 由来（docs/bugfixes/2026-08-12-instant-tooltip-first-show-far-off.md）：
# NSHostingView 直接当 contentView 时会把自己的尺寸约束灌成窗口的 contentMinSize
# （一条 24pt 的提示报出 min 高度 332），面板随后被撑高，气泡垂直居中 ——
# 用户看到的是「提示第一次弹在很远的地方」。
#
# 用法：
#   scripts/check-instant-tooltip-panel.sh
#
# 需要能连上窗口服务器（会真的建 NSWindow / NSPanel，但用 .accessory 策略，
# 不抢焦点、不进 Dock）。hover 本身没法合成，所以自检直接调控制器，绕开鼠标。
set -euo pipefail
cd "$(dirname "$0")/.."

# Rosetta 终端下必须显式指定 arm64，否则会去编 x86_64（见 docs/build/）。
TRIPLE="arm64-apple-macosx15.0"

OUT="$(mktemp -d)/tooltippanel"
trap 'rm -rf "$(dirname "$OUT")"' EXIT

echo "==> 编译自检二进制"
# SwiftPM/swiftc 的诊断走 stdout：静默成功可以，失败必须倾倒完整输出
#（>/dev/null 会把编译错误吞成无字天书，见 docs/bugfixes/ 2026-08-08 CI 首跑案例）。
xcrun swiftc \
  -target "$TRIPLE" \
  -o "$OUT" \
  Sources/SrtFlow/InstantTooltip.swift \
  Sources/SrtFlow/AppLanguage.swift \
  checks/InstantTooltipPanel/main.swift

echo "==> 运行"
"$OUT"
