#!/bin/bash
# 重放一次「从别的 App 把文件拖进被测窗口」。
#
# 为什么要自己造一个拖源：Finder **不吃合成事件**，CGEvent 驱动它不会起
# NSDraggingSession，所以从 Finder 拖文件这条路没法直接自动化。这里用一个最小的
# AppKit App 当拖源 —— 它起的是真正的跨进程拖放会话，被测 App 那边分不出区别。
#
# 判据看拖源那边的 `draggingSession(_:endedAt:operation:)`：
#   op=0  没人要（落点区被谁认领了又扔掉，或者压根没有落点区）
#   op=1  被接受（.copy）
# 这一条比被测 App 自己的日志更硬：它是拖放会话的最终结果，不依赖被测 App 记账。
#
# 背景与它当初钉死的那个 bug：
# docs/bugfixes/2026-09-23-timeline-file-drop-claimed-by-inner-drop-region.md
#
# 用法：
#   scripts/gui-smoke/external-file-drag/replay.sh <要拖的文件> <落点x> <落点y>
#
# 坐标是**全局屏幕坐标、左上为原点**，和 System Events 报的窗口 position 同一套：
#   osascript -e 'tell application "System Events" to get {position, size} of window 1 of process "SrtFlowDev"'
# 拿到窗口左上角之后加上窗口内偏移即可。
#
# 需要「辅助功能」权限（终端 / Claude Code）才能合成鼠标事件，同 GUI 冒烟的其余部分。
set -euo pipefail

FILE="${1:?用法: replay.sh <文件> <落点x> <落点y>}"
TO_X="${2:?缺落点 x}"
TO_Y="${3:?缺落点 y}"

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${TMPDIR:-/tmp}/srtflow-drag-harness"
LOG="$OUT/dragsource.log"
mkdir -p "$OUT/DragSource.app/Contents/MacOS"

cat > "$OUT/DragSource.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>DragSource</string>
<key>CFBundleIdentifier</key><string>com.srtflow.dragsource</string>
<key>CFBundleName</key><string>DragSource</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

# 拖源窗口摆在主屏右上角，避免盖住被测窗口（NSWindow 用左下原点，这里换算一下）。
SRC_W=200; SRC_H=140
read -r SCREEN_W SCREEN_H <<EOF
$(osascript -e 'tell application "Finder" to get bounds of window of desktop' | awk -F', *' '{print $3, $4}')
EOF
SRC_X=$(( SCREEN_W - SRC_W ))
SRC_BOTTOM=$(( SCREEN_H - 48 - SRC_H ))

[ -x "$OUT/DragSource.app/Contents/MacOS/DragSource" ] && [ "$OUT/DragSource.app/Contents/MacOS/DragSource" -nt "$HERE/DragSource.swift" ] \
  || swiftc -O -o "$OUT/DragSource.app/Contents/MacOS/DragSource" "$HERE/DragSource.swift"
[ -x "$OUT/dodrag" ] && [ "$OUT/dodrag" -nt "$HERE/DoDrag.swift" ] \
  || swiftc -O -o "$OUT/dodrag" "$HERE/DoDrag.swift"
codesign --force --sign - "$OUT/DragSource.app" >/dev/null 2>&1

# 同名进程坑（见 docs/testing/gui-smoke-testing.md）：别处编出来的同一个 bundle id
# 还活着的话，`open` 只会把它叫到前台，日志写去别处，这里就等不到。全杀。
pkill -x DragSource 2>/dev/null || true
sleep 0.5
rm -f "$LOG"
# 必须用 open 起：后台直接拉起来的进程会跟着调用方一起被收走。
open -a "$OUT/DragSource.app" --args "$FILE" "$SRC_X" "$SRC_BOTTOM" "$LOG"
sleep 2

read -r WIN_X WIN_Y <<EOF
$(osascript -e 'tell application "System Events" to get position of window 1 of process "DragSource"' | tr ',' ' ')
EOF
FROM_X=$(( WIN_X + SRC_W / 2 ))
# 标题栏约 28pt，起手点落在内容区中间。
FROM_Y=$(( WIN_Y + 28 + SRC_H / 2 ))

"$OUT/dodrag" "$FROM_X" "$FROM_Y" "$TO_X" "$TO_Y" >/dev/null
sleep 1.5

echo "拖源日志（${LOG}）："
cat "$LOG"
if grep -q 'op=1' "$LOG"; then
  echo "→ op=1：落点被接受"
elif grep -q 'op=0' "$LOG"; then
  echo "→ op=0：没人要 —— 那个位置没有活的文件落点区，或者被谁认领了又扔掉"
else
  echo "→ 拖放会话没结束：起手点大概不在拖源窗口上（看上面的 mouseDown 有没有）"
  exit 1
fi
