#!/usr/bin/env bash
# checks/timeline-drag-wiring.sh 的一节：文字块上下换行（2026-09-24，§5j）。
#
# **不单独跑**：由 timeline-drag-wiring.sh 用 `source` 装进来，共用它的 fail / grep_code /
# require_func / extract_func 和路径变量。合同见 docs/architecture/text-overlays.md
# 「时间线上的行」与 docs/architecture/timeline-drag-gestures.md §5j。

TEXT_ROWS="Sources/SrtFlow/VideoEditTextRows.swift"
TEXT_ROW_DROP="Sources/SrtFlow/VideoEditTimelineTextRowDrop.swift"
for f in "$TEXT_ROWS" "$TEXT_ROW_DROP" "$ROW_SELECT_RULE"; do
  [ -f "$f" ] || fail "文件不在：$f"
done
# 1) 行号进模型之后，时间线 / 框选 / 行头点选都只准读 `row`，不许再按时间重叠现算。
#    `TextOverlayStacking` 只剩迁移（normalizeTextRows）这一个调用点。
for f in "$VIEW" "$TEXT_ROW" "$MARQUEE_VIEW" "$ROW_SELECT_RULE" "$DRAG_WIRING"; do
  grep_code 'TextOverlayStacking' "$f" \
    && fail "$f 还在按时间重叠现算文字行（TextOverlayStacking）：行号已进模型，读 row"
done
STACKING_CALLS="$(grep -rn 'TextOverlayStacking\.' Sources/SrtFlow --include='*.swift' \
  | grep -v '^[^:]*:[0-9]*:[[:space:]]*//' | grep -v "$TEXT_ROWS" || true)"
[ -z "$STACKING_CALLS" ] || fail "TextOverlayStacking 只准在迁移里调：$STACKING_CALLS"
grep_code 'textOverlays(onRow: row)' "$TEXT_ROW" || fail "文字行没按 row 取字"
grep_code 'textOverlays(onRow: row)' "$MARQUEE_VIEW" || fail "框选的文字行没按 row 取字"
grep_code 'textOverlays(onRow: row)' "$ROW_SELECT_RULE" || fail "行头点选没按 row 取字"
# 2) 目标行只是视图状态（在拖动盒子里，§0b）：拖动中不写 state；松手清掉；视图消失清掉。
grep_code '@Published private(set) var textDropRow: Int?' "Sources/SrtFlow/VideoEditTimelineDragBox.swift" \
  || fail "目标行不是拖动盒子里的视图状态（textDropRow）"
if BODY="$(require_func 'func aimVertically(' "$DRAG_WIRING")"; then
  grep -q 'dragBox.aim(textRow: textRowTarget(for: drag))' <<<"$BODY" \
    || fail "aimVertically 没给文字块判目标行（textRowTarget）"
  grep -q 'drag.subject == .text' <<<"$BODY" \
    || fail "aimVertically 没把文字块和跨轨拖动分开：文字会进缝、换轨"
fi
if BODY="$(require_func 'func textRowTarget(' "$DRAG_WIRING")"; then
  grep -q 'TextRows.dropTarget(' <<<"$BODY" || fail "目标行判定没走纯值的 TextRows.dropTarget"
  grep -q 'scrollGeometry.offsetY' <<<"$BODY" || fail "目标行没加现读的纵向滚动量（§5c）"
  for forbidden in 'project.perform' 'liveApply' 'moveTextOverlay'; do
    grep -q "$forbidden" <<<"$BODY" && fail "textRowTarget 里出现了 ${forbidden}：拖动中禁止写 state"
  done
fi
if BODY="$(require_func 'func endClipDrag(' "$DRAG_WIRING")"; then
  grep -q 'dragBox.end()' <<<"$BODY" || fail "松手没清 textDropRow（dragBox.end()）"
  grep -q 'textRow: dragBox.textDropRow' <<<"$BODY" || fail "松手没把目标行交给 commitFreeDrag：换行不落地"
fi
if BODY="$(require_func 'func end()' "Sources/SrtFlow/VideoEditTimelineDragBox.swift")"; then
  grep -q 'textDropRow = nil' <<<"$BODY" || fail "TimelineDragBox.end 没清 textDropRow"
fi
if BODY="$(extract_func '.onDisappear {' "$VIEW")"; then
  grep -q 'dragBox.reset()' <<<"$BODY" || fail "onDisappear 没清 textDropRow（dragBox.reset()）"
fi
# 3) 落地：换行和横向位移在同一次 perform 里（一步撤销），落点被占往上找。
if BODY="$(require_func 'func commitFreeDrag(' "$PROJECT")"; then
  grep -q 'state.settleTextRow(plan, preferring: textRow)' <<<"$BODY" \
    || fail "commitFreeDrag 没在同一次 perform 里落文字的行（settleTextRow）"
fi
if BODY="$(require_func 'mutating func moveTextOverlay(' "$TEXT_ROWS")"; then
  grep -q 'freeTextRow(' <<<"$BODY" || fail "换行没走「被占往上找」（freeTextRow）"
  grep -q 'compactTextRows()' <<<"$BODY" || fail "换行之后没收拢空行"
fi
# 4) 新加的字永远在最上面新开一行；删了收拢；导出和预览同一份叠放序。
[ "$(grep -c 'overlay.row = state.textRowCount' Sources/SrtFlow/VideoEditProject+Text.swift)" -ge 2 ] \
  || fail "加文字 / 数字没有在最上面新开一行（overlay.row = state.textRowCount 要有两处）"
grep_code 'compactTextRows()' Sources/SrtFlow/VideoEditProject+Text.swift || fail "删文字后没收拢空行"
grep_code 'compactTextRows()' "$PROJECT" || fail "deleteSelected 删文字后没收拢空行"
grep_code 'textOverlaysInStackingOrder' Sources/SrtFlow/VideoEditExportGraph.swift \
  || fail "导出没按叠放序贴文字：成片里谁压谁和预览不一样"
grep_code 'textOverlaysInStackingOrder' Sources/SrtFlow/VideoEditProject+Text.swift \
  || fail "预览叠层没按叠放序画文字"
grep_code 'timeline.normalizeTextRows()' Sources/SrtFlow/VideoEditProjectFile.swift \
  || fail "载入没补老工程的行号（normalizeTextRows）"
