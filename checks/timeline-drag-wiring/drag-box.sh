#!/usr/bin/env bash
# checks/timeline-drag-wiring.sh 的一节：拖动 / 拉框的会话不进时间线的 @State（2026-09-25，§0b）。
#
# **不单独跑**：由 timeline-drag-wiring.sh 用 `source` 装进来，共用它的 fail / grep_code /
# require_func / extract_func 和路径变量。合同见 docs/architecture/timeline-drag-gestures.md §0b，
# 案例 docs/bugfixes/2026-09-25-drag-session-in-timeline-state.md。
#
# 病根一句话：会话是时间线的 `@State` 时，拖动每一拍写一次，时间线的 body 就整个重算一次
# —— 块靠 `.equatable()` 挡住了自己的 body，ForEach 的 diff、AttributeGraph 的更新和布局挡不住
#（采样里占拖动中主线程约 75%）。现在会话在 `TimelineDragBox` 里：时间线 `@State` 持有、不订阅；
# 块各自 `onReceive` 自己那份位移 / 框选命中；覆盖层 `TimelineDragOverlay` 是唯一的订阅者。

DRAG_BOX="Sources/SrtFlow/VideoEditTimelineDragBox.swift"
DRAG_OVERLAY="Sources/SrtFlow/VideoEditTimelineDragOverlay.swift"
FILTER_ROW="Sources/SrtFlow/VideoEditTimelineFilterRow.swift"
for f in "$DRAG_BOX" "$DRAG_OVERLAY" "$FILTER_ROW"; do
  [ -f "$f" ] || fail "文件不在：$f"
done

# 1) 时间线用 @State **持有**盒子、不订阅（@StateObject / @ObservedObject 都是订阅：每一拍整棵树重算）。
grep_code '@State var dragBox = TimelineDragBox()' "$VIEW" \
  || fail "时间线主体必须用 @State 持有拖动盒子（@State var dragBox = TimelineDragBox()）"
if grep -vE '^[[:space:]]*//' "$VIEW" | grep -cE '@(StateObject|ObservedObject) (private )?var dragBox' >/dev/null; then
  fail "时间线主体订阅了拖动盒子：拖动每一拍整条时间线都会重算（§0b）"
fi
# 会话不许回到时间线的 @State：这几个名字曾经就是 @State，回来一个就是每拍重算一次。
for stale in 'clipDrag' 'marquee' 'dragTargetRow' 'textDropRow' 'movingCueID'; do
  if grep -vE '^[[:space:]]*//' "$VIEW" | grep -cE "@State (private )?var ${stale}\b" >/dev/null; then
    fail "拖动会话又回到时间线的 @State 了（${stale}）：拖动每一拍整条时间线重算（§0b）"
  fi
done
# 弹性尾部是时间线仅剩的那个拖动中会写的 @State：只许一档一档地涨，不许跟着每一拍变。
if BODY="$(require_func 'private func growTail(' "$DRAG_WIRING")"; then
  grep -q 'guard needed > dragTailWidth else { return }' <<<"$BODY" \
    || fail "growTail 没有「够用就不写」的门槛：弹性尾部会跟着每一拍写时间线的 @State"
  grep -q 'rounded(.up) \* step' <<<"$BODY" \
    || fail "growTail 不是按档往上跳：内容宽度跟着终点走 = 每一拍重算整条时间线"
fi
# 2) 订阅盒子的只许是覆盖层 —— 扫**全部**源文件，不只时间线这一族（反向验证时往
#    TextRowDrop 里塞一个订阅，按族扫的版本没红）。
SUBSCRIBERS="$(grep -rlE '@(ObservedObject|StateObject) (private )?var [A-Za-z]+: TimelineDragBox' Sources/SrtFlow --include='*.swift' 2>/dev/null | sort -u | tr '\n' ' ' | sed 's/ $//')"
[ "$SUBSCRIBERS" = "$DRAG_OVERLAY" ] \
  || fail "订阅拖动盒子的不只是 TimelineDragOverlay：[${SUBSCRIBERS}]（块只许 onReceive 自己那份）"
# 3) 五种块：位移和框选命中都从盒子里**收**（onReceive），不再当输入 —— 当输入的话时间线每一拍
#    都得重算一遍来喂它。构造处传的是盒子本身。
for spec in \
  "$CLIP_BLOCK|clip.id|clips|$VIEW|selectedClipIDs.contains(clip.id)" \
  "$SHAPE_ROW|shape.id|shapes|$SHAPE_ROW|selectedShapeIDs.contains(shape.id)" \
  "$TEXT_ROW|overlay.id|texts|$TEXT_ROW|selectedTextIDs.contains(overlay.id)" \
  "$FILTER_ROW|filter.id|filters|$FILTER_ROW|selectedFilterIDs.contains(filter.id)" \
  "$CUE_BLOCK|cue.id|cues|$SUBTITLE_ROW|selectedSubtitleCueIDs.contains(cue.id)"; do
  IFS='|' read -r block id kind host selected <<<"$spec"
  grep_code "onReceive(drag.offsets(member: isDragMember))" "$block" \
    || fail "${block} 没按「是成员才订阅」收位移（onReceive(drag.offsets(member: isDragMember))）：要么拖不动，要么 150 个块每一拍都被标脏"
  grep_code "offsets.offset(for: ${id})" "$block" \
    || fail "${block} 收位移时没按自己的 id 取（offsets.offset(for: ${id})）"
  grep_code "onReceive(drag.\$marqueeHit)" "$block" \
    || fail "${block} 没从盒子里收框选命中（onReceive(drag.\$marqueeHit)）：拖框中不会实时高亮"
  grep_code "\$0.${kind}.contains(${id})" "$block" \
    || fail "${block} 收框选命中时没按自己那一类取（\$0.${kind}.contains(${id})）"
  grep_code 'let drag: TimelineDragBox' "$block" \
    || fail "${block} 没拿着盒子（let drag: TimelineDragBox）"
  if grep -vE '^[[:space:]]*//' "$block" | grep -cE 'let dragOffset: Double\?' >/dev/null; then
    fail "${block} 又把位移当输入了（let dragOffset: Double?）：时间线每一拍都得重算来喂它"
  fi
  grep_code 'marqueeHit ?? isSelected' "$block" \
    || fail "${block} 画选中态时没先看框（marqueeHit ?? isSelected）：拖框中不会实时高亮"
  grep_code 'drag: dragBox' "$host" \
    || fail "${host} 构造块时没把盒子传进去（drag: dragBox）"
  grep_code "isDragMember: dragMembers.contains(${id})" "$host" \
    || fail "${host} 构造块时没按成员名单传 isDragMember（dragMembers.contains(${id})）"
  grep_code "isSelected: project.${selected}" "$host" \
    || fail "${host} 的选中态输入不是模型里的选中（isSelected: project.${selected}）"
done
#    成员名单是时间线的 @State，一轮只写两次（起手、松手、视图消失）。
grep_code '@State var dragMembers: Set<UUID> = \[\]' "$VIEW" || fail "时间线没有 dragMembers（成员才订阅位移）"
if BODY="$(require_func 'private func startDrag(' "$DRAG_WIRING")"; then
  grep -q 'dragMembers = session.movingIDs' <<<"$BODY" || fail "startDrag 没把成员名单写进 dragMembers：没有块会订阅位移"
fi
if BODY="$(require_func 'func offsets(member: Bool)' "$DRAG_BOX")"; then
  grep -q 'Self.silence' <<<"$BODY" || fail "TimelineDragBox.offsets(member:) 对非成员没有给永远不发的发布者"
fi
# 4) 盒子只在变了时才发：每一拍都写、很少变的那几个（目标行、文字行、位移）都要先比。
if BODY="$(require_func 'func update(_ session: ClipDragSession)' "$DRAG_BOX")"; then
  grep -q 'if offsets.offset != session.offset' <<<"$BODY" \
    || fail "TimelineDragBox.update 没比过就发位移：位移没变的那一拍全部块都会被叫醒"
fi
if BODY="$(require_func 'func aim(row: DragRowTarget?)' "$DRAG_BOX")"; then
  grep -q 'if dragTargetRow != row' <<<"$BODY" || fail "TimelineDragBox.aim(row:) 没比过就发"
fi
if BODY="$(require_func 'func aim(textRow: Int?)' "$DRAG_BOX")"; then
  grep -q 'if textDropRow != textRow' <<<"$BODY" || fail "TimelineDragBox.aim(textRow:) 没比过就发"
fi
if BODY="$(require_func 'func updateMarquee(' "$DRAG_BOX")"; then
  grep -q 'if marqueeHit != session.hit' <<<"$BODY" \
    || fail "TimelineDragBox.updateMarquee 没比过就发命中：框每挪一个点全部块都会被叫醒"
fi
# 5) 一轮结束什么都不许留（cue 的起手记号、目标行、文字行、位移）。
if BODY="$(require_func 'func end()' "$DRAG_BOX")"; then
  for cleared in 'clipDrag = nil' 'offsets = DragOffsets()' 'dragTargetRow = nil' 'textDropRow = nil' 'movingCueID = nil'; do
    grep -qF "$cleared" <<<"$BODY" || fail "TimelineDragBox.end 没清 ${cleared%% *}"
  done
fi
if BODY="$(require_func 'func endClipDrag' "$DRAG_WIRING")"; then
  grep -q 'dragBox.end()' <<<"$BODY" || fail "endClipDrag 没收掉盒子里的会话（dragBox.end()）"
  grep -q 'if dragTailWidth != 0 { dragTailWidth = 0 }' <<<"$BODY" \
    || fail "endClipDrag 没把弹性尾部归零（或者没比过就写：白白重算一次时间线）"
  grep -q 'if !dragMembers.isEmpty { dragMembers = \[\] }' <<<"$BODY" \
    || fail "endClipDrag 没清成员名单：下一轮别的块还订阅着上一轮的位移"
fi
if BODY="$(extract_func '.onDisappear {' "$VIEW")"; then
  grep -q 'dragBox.reset()' <<<"$BODY" || fail "onDisappear 没清拖动盒子（dragBox.reset()）：下一次拖同一条 cue 会失效一次"
  grep -q 'dragMembers = \[\]' <<<"$BODY" || fail "onDisappear 没清成员名单"
fi
# 6) 拖动中每一拍只写盒子：updateClipDrag / aimVertically 里不许写时间线的 @State（除了那一档弹性尾部）。
for entry in 'func updateClipDrag' 'func aimVertically('; do
  if BODY="$(require_func "$entry" "$DRAG_WIRING")"; then
    if grep -vE '^[[:space:]]*//' <<<"$BODY" | grep -cE '^[[:space:]]*(clipDrag|marquee|dragTargetRow|textDropRow|movingCueID) = ' >/dev/null; then
      fail "${entry} 直接写了时间线的状态：拖动会话只许进盒子（dragBox.update / aim）"
    fi
  fi
done
