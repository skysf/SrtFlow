#!/usr/bin/env bash
# FalKeyStore 对真的系统钥匙串走一遍：存 → 有 → 读到 → 换 → 删。
#
# **不在 check-all.sh 里**：要一个能用的用户钥匙串（CI 的 runner 没有图形会话，钥匙串不一定开着，
# 假红 / 假绿都不能接受 —— 跳过更不能报成通过）。改 `Sources/SrtFlow/Fal/FalKeyStore.swift` 之后本机跑一遍。
# 用专门的服务名（check.srtflow.fal.<pid>），跑完一定删掉。同一个进程建的项自己读不弹授权框；「换了签名要弹框」
# 那一半要两个不同签名的进程，见 docs/architecture/fal-generation.md 的人工回归清单。
#
# 用法：
#   scripts/check-fal-keychain.sh
set -euo pipefail
cd "$(dirname "$0")/.."

# Rosetta 终端下必须显式指定 arm64（见 docs/build/）。
TRIPLE="arm64-apple-macosx15.0"

OUT="$(mktemp -d)/falkeychaincheck"
trap 'rm -rf "$(dirname "$OUT")"' EXIT

echo "==> 编译"
xcrun swiftc \
  -target "$TRIPLE" \
  -o "$OUT" \
  Sources/SrtFlow/Fal/FalKeyStore.swift \
  checks/FalKeychain/main.swift

echo "==> 跑（真的钥匙串）"
# 看门狗：万一弹了授权框、进程卡在框上，30 秒后杀掉并判红，不许无限挂着。
"$OUT" &
PID=$!
( sleep 30; kill -9 "$PID" 2>/dev/null ) &
WATCHDOG=$!
if wait "$PID"; then
  kill "$WATCHDOG" 2>/dev/null || true
else
  kill "$WATCHDOG" 2>/dev/null || true
  echo "✗ 钥匙串检查失败或卡住（可能弹了授权框）" >&2
  exit 1
fi
