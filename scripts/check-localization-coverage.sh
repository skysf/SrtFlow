#!/usr/bin/env bash
# **本地化覆盖守卫**：源码里写死的界面文案，必须 en 和 zh-Hans 两张表都有。
#
# 由来（docs/bugfixes/2026-08-12-instant-tooltip-first-show-far-off.md）：
# 本地化查不到是静默降级 —— 不报错、不崩，只是中文界面里原样显示英文。用户
# 报上来的那批英文 tooltip 就是这么来的，一次扫出 132 条从没进过表的文案。
#
# 用法：
#   scripts/check-localization-coverage.sh
#
# 纯静态扫描，不需要窗口服务器，也不跑 App。
set -euo pipefail
cd "$(dirname "$0")/.."

# Rosetta 终端下必须显式指定 arm64，否则会去编 x86_64（见 docs/build/）。
TRIPLE="arm64-apple-macosx15.0"

OUT="$(mktemp -d)/l10ncoverage"
trap 'rm -rf "$(dirname "$OUT")"' EXIT

echo "==> 编译自检二进制"
# 诊断走 stdout：静默成功可以，失败必须倾倒完整输出
#（>/dev/null 会把编译错误吞成无字天书，见 docs/bugfixes/ 2026-08-08 CI 首跑案例）。
xcrun swiftc -target "$TRIPLE" -o "$OUT" checks/LocalizationCoverage/main.swift

echo "==> 运行"
"$OUT"
