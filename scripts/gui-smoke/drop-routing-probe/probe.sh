#!/bin/bash
# 起落点路由探针，打印每一格的中心点（全局屏幕坐标、左上原点）。
#
# 用法：
#   scripts/gui-smoke/drop-routing-probe/probe.sh
# 然后：
#   外部拖入 —— scripts/gui-smoke/external-file-drag/replay.sh <任意文件> <x> <y>
#               （op=1 被接受、op=0 没人要），再看探针日志里是哪一格收到了回调；
#   App 内拖动 —— 人手把顶上的 A / B 卡片拖到各格上（合成事件驱动不了 `.onDrag`）。
#
# 各格是什么组合、2026-09-23 测出来的结果，见
# docs/bugfixes/2026-09-23-in-app-drops-swallowed-by-file-underlay.md。
# 需要「辅助功能」权限才能跑 replay.sh，同 GUI 冒烟的其余部分。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${TMPDIR:-/tmp}/srtflow-drop-probe"
APP="$OUT/DropProbe.app"
LOG="$OUT/probe.log"
mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>DropProbe</string>
<key>CFBundleIdentifier</key><string>com.srtflow.dropprobe</string>
<key>CFBundleName</key><string>DropProbe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

# Rosetta 终端下显式编 arm64（见 docs/build/）。
[ -x "$APP/Contents/MacOS/DropProbe" ] && [ "$APP/Contents/MacOS/DropProbe" -nt "$HERE/Probe.swift" ] \
  || xcrun swiftc -target arm64-apple-macosx15.0 -O -o "$APP/Contents/MacOS/DropProbe" "$HERE/Probe.swift"
codesign --force --sign - "$APP" >/dev/null 2>&1

# 同名进程坑（docs/testing/gui-smoke-testing.md）：旧的还活着的话 open 只会把它叫到前台。
pkill -x DropProbe 2>/dev/null || true
sleep 0.5
rm -f "$LOG"
# 必须用 open 起：后台直接拉起来的进程会跟着调用方一起被收走。
open -a "$APP" --args "$LOG"
sleep 3

echo "探针日志：${LOG}"
grep 'REGION' "$LOG" | sed 's/^[0-9.]* REGION /  /' | sort
