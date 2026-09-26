#!/usr/bin/env bash
# 时间线缩放的锚点自检：横向缩放后锚点那一刻回到视口里原来那个 x、工具栏缩放钉播放头（不在视口里
# 钉视口正中）、纵向缩放后锚点那一行的那一处回到原来那个 y（行内按比例、缝里按距离）。
#
# 用法：
#   scripts/check-timeline-zoom.sh
#
# 与 check-timeline-snap.sh 同一套编法：被测代码在 SrtFlow app target 里，SwiftPM 不允许两个
# target 共用源文件，所以单独编成自检二进制来跑。锚点的算术是纯值、单独放在
# Sources/SrtFlow/VideoEditTimelineZoomAnchor.swift（不 import AppKit）才编得动 ——
# 别把它挪进 VideoEditTimelineZoom.swift，那个文件拖着工程和滚动视图。
# 接线（捏合从时间线自己的滚动几何量锚点、不许 hitTest 找滚动视图）钉在
# checks/timeline-drag-wiring.sh；长期约束见 docs/architecture/timeline-pinch-zoom.md。
set -euo pipefail
cd "$(dirname "$0")/.."

# Rosetta 终端下必须显式指定 arm64，否则会去编 x86_64（见 docs/build/）。
TRIPLE="arm64-apple-macosx15.0"

OUT="$(mktemp -d)/zoomcheck"
trap 'rm -rf "$(dirname "$OUT")"' EXIT

echo "==> 编译自检二进制"
xcrun swiftc \
  -target "$TRIPLE" \
  -wmo \
  -o "$OUT" \
  Sources/SrtFlow/VideoEditTimelineZoomAnchor.swift \
  checks/TimelineZoom/main.swift

echo "==> 运行"
"$OUT"
