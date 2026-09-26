#!/usr/bin/env bash
# checks/timeline-drag-wiring.sh 的一节：时间线缩放的接线（横向 + 纵向）。
#
# **不单独跑**：由 timeline-drag-wiring.sh 用 `source` 装进来，共用它的 fail / grep_code /
# require_func / extract_func 和路径变量（VIEW、ZOOM、PROJECT …）。拆出来是因为主文件超过了
# 单文件上限、只许降不许涨（docs/architecture/coding-standards.md）。
# 锚点的算术是纯值，由 scripts/check-timeline-zoom.sh 钉；这里钉「接没接对」。
# 长期约束见 docs/architecture/timeline-pinch-zoom.md。

ZOOM_ENTRY="Sources/SrtFlow/VideoEditTimelineZoom.swift"
ZOOM_ANCHOR_MATH="Sources/SrtFlow/VideoEditTimelineZoomAnchor.swift"
EDITOR_ROOT="Sources/SrtFlow/VideoEditView.swift"
for f in "$ZOOM_ENTRY" "$ZOOM_ANCHOR_MATH" "$EDITOR_ROOT"; do
  [ -f "$f" ] || fail "找不到 ${f}：缩放的入口 / 锚点算术挪走了，这一节会扫个空"
done

# ── 6a. 缩放只有一个会夹范围的入口 ─────────────────────────────────────
# pps 掉到 1 以下时，位移换算会被 max(pps, 1) 兜底，1:1 跟手当场坏掉。捏合、滚轮、工具栏、
# 滑杆都走 TimelineZoom.horizontal，它里面只走 setPixelsPerSecond。
grep_code 'pixelsPerSecond = \|pixelsPerSecond.wrappedValue' "$ZOOM" \
  && fail "捏合自己给 pixelsPerSecond 赋值了：缩放只许走 TimelineZoom → setPixelsPerSecond"
grep_code 'project.setPixelsPerSecond(scale)' "$ZOOM_ENTRY" \
  || fail "TimelineZoom.horizontal 没走 setPixelsPerSecond（唯一会夹范围的缩放入口）"
grep -rn 'project.pixelsPerSecond = \|pixelsPerSecond = min(\|pixelsPerSecond = max(' "$EDITOR_ROOT" \
  && fail "工具栏绕开了唯一缩放入口"

# ── 6b. 捏合的锚点从时间线自己的滚动几何量（2026-09-26 案例） ─────────────
# 以前按坐标 hitTest 去找滚动视图，传进去的是翻转过的根视图坐标 —— 找的是窗口里上下对称的那一处
# （预览区），找不到时间线，锚点那一步从来没生效：放大时画面从左边往右涨，指针底下的东西被推走
# （docs/bugfixes/2026-09-26-pinch-zoom-anchor-never-applied.md）。
grep_code '\.hitTest(' "$ZOOM" \
  && fail "捏合又按坐标 hitTest 去找滚动视图了：锚点要从时间线自己的 TimelineScrollGeometry 量"
grep_code 'enclosingScrollView' "$ZOOM" \
  && fail "捏合又自己去认滚动视图了：滚动视图只由 TimelineScrollViewAccessor 交给滚动几何"
grep_code 'TimelineMagnificationBridge(project: project, geometry: scrollGeometry)' "$VIEW" \
  || fail "捏合的桥没拿到时间线自己的滚动几何（scrollGeometry）"
if BODY="$(require_func 'static func pointerAnchor(' "$ZOOM_ENTRY")"; then
  grep -q 'location(ofWindowPoint: point, in: window)' <<<"$BODY" \
    || fail "指针底下那一刻没按滚动几何换算（location(ofWindowPoint:)）"
fi
if BODY="$(require_func 'static func horizontal(' "$ZOOM_ENTRY")"; then
  grep -q 'geometry.keepAnchored(' <<<"$BODY" \
    || fail "横向缩放改完比例没把锚点拉回原位（keepAnchored）"
fi

# ── 6c. 工具栏的放大缩小、⌘= ⌘-、滑杆钉住播放头（2026-09-26 用户拍板） ─────
# 以前只改比例、不管滚动：一按画面就跳。两个按钮 + 滑杆，三处都要钉。
COUNT="$(grep -c 'keeping: \.playheadOrCenter' "$EDITOR_ROOT" || true)"
[ "$COUNT" -ge 3 ] \
  || fail "工具栏上钉住播放头的缩放只有 ${COUNT} 处，应当 3 处（放大、缩小、滑杆）"
# 缩放滑杆是对数刻度（线性的话原来的整个区间挤在最左 2%），写入走钉播放头的那个入口。
grep_code 'Slider(value: zoomSliderBinding' "$EDITOR_ROOT" \
  || fail "缩放滑杆不是对数刻度的那个 binding 了"
if BODY="$(awk '/private var zoomSliderBinding/,/^    \}$/' "$EDITOR_ROOT")"; then
  grep -q 'TimelineZoom.horizontal(project, to: exp(' <<<"$BODY" \
    || fail "缩放滑杆没走 TimelineZoom.horizontal（钉住播放头、里面才是唯一的缩放入口）"
fi

# ── 6d. 纵向缩放：⌥ 捏合 / ⌥ + Ctrl + 滚轮 / ⌘↓ ⌘↑，视频和音频轨统一成一个高度 ─────
grep_code 'zoomsVertically = event.modifierFlags.contains(.option)' "$ZOOM" \
  || fail "按住 ⌥ 捏合不再是纵向缩放了（或者没在起手时定轴，捏到一半会换轴）"
if BODY="$(require_func 'private func handleScrollWheel(' "$ZOOM")"; then
  grep -q 'event.modifierFlags.contains(.option)' <<<"$BODY" \
    || fail "⌥ + Ctrl + 滚轮不再是纵向缩放了（没有触控板时就没法纵向缩放）"
fi
grep_code '\[125, 126\].contains(event.keyCode), modifiers == \[.command\]' "$EDITOR_ROOT" \
  || fail "⌘↓ / ⌘↑ 纵向缩放的按键没接（或者带了别的修饰键也会触发）"
if BODY="$(require_func 'static func vertical(' "$ZOOM_ENTRY")"; then
  grep -q 'project.updateRowHeights { $0.setUniform(' <<<"$BODY" \
    || fail "纵向缩放没走统一高度（setUniform）：用户拍板的是「所有轨变成一样高，单独调过的作废」"
  grep -q 'geometry.keepAnchored(x: nil' <<<"$BODY" \
    || fail "纵向缩放没把锚点拉回原位，或者碰了横向滚动（§5b：没在推的轴一个字都不许碰）"
fi
# 行高的写入口不许进撤销栈 / 重建预览（拖轨道头和纵向缩放共用它）。
if BODY="$(require_func 'func updateRowHeights(' "$PROJECT")"; then
  for forbidden in 'perform' 'liveApply' 'state =' 'scheduleRebuild'; do
    grep -q "$forbidden" <<<"$BODY" \
      && fail "updateRowHeights 里出现了 ${forbidden}：行高是装饰状态，不许进撤销栈/重建预览"
  done
  grep -q 'documentDidChange()' <<<"$BODY" \
    || fail "updateRowHeights 没标脏：缩放 / 拖好的行高不会被自动保存带进工程文件"
fi

# ── 6e. 纵向滚下去之后，钉住的标尺行压在轨道行上面（2026-09-26 案例 tracks-cover-pinned-ruler） ──
# 纵向缩放让纵向滚动成了家常便饭。叠放次序只认最外面那一层 `.zIndex`：每一行都挂着换位位移
# （`laneReorderOffset`，里面有 `.zIndex`），标尺自己写的 `.zIndex(50)` 被盖成 0，轨道行画到标尺上面。
if BODY="$(require_func 'func laneReorderOffset(' "$LANE_REORDER")"; then
  grep -q 'zIndex(pinnedOnTop ? 50' <<<"$BODY" \
    || fail "换位位移盖掉了钉住的标尺行的层级：纵向滚下去之后轨道行会画到标尺上面"
fi
grep_code 'offset(y: row.isRuler ? geometry.offset.y : 0)' "$HEADER_COLUMN" \
  || fail "轨道头列的标尺那一行（总推子）没钉在顶上：滚下去之后它跟着滚走，轨道头挨着标尺、对不上"
