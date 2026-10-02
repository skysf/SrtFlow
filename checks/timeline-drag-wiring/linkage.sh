#!/usr/bin/env bash
# checks/timeline-drag-wiring.sh 的一节：联动（2026-10-02）—— 压在主轨块上的东西跟着它的画面走的接线。
#
# **不单独跑**：由 timeline-drag-wiring.sh 用 `source` 装进来，共用它的 fail / grep_code / require_func 和
# 路径变量（PROJECT …）。规则本身（跟着画面走、跨段、真删才删、撞上让开）由 scripts/check-timeline-snap.sh
# 第 1f 组钉；这里钉「接没接对」：规则只有一处、每次改动都经过它、真删的入口说了自己是真删、拖动计划带上压着的东西。
# 长期约束见 docs/architecture/timeline-linkage.md。

LINKAGE="Sources/SrtFlow/VideoEditTimelineLinkage.swift"
LINKAGE_LANDING="Sources/SrtFlow/VideoEditTimelineLinkageLanding.swift"
AI_TIMELINE_TOOLS="Sources/SrtFlow/AITimelineTools.swift"
AI_SPEECH_CUT="Sources/SrtFlow/AISpeechCutTool.swift"
MCP_TIMELINE="Sources/SrtFlowMCPKit/MCPTimelineTools.swift"
MCP_SMART="Sources/SrtFlowMCPKit/MCPSmartEditTools.swift"
for f in "$LINKAGE" "$LINKAGE_LANDING" "$AI_TIMELINE_TOOLS" "$AI_SPEECH_CUT" "$MCP_TIMELINE" "$MCP_SMART"; do
  [ -f "$f" ] || fail "找不到 ${f}：联动的代码挪走了，这一节会扫个空"
done

# ── 12a. 规则只有一处，每次改动收尾都经过它（磁吸合拢之后、补色之前） ───────
if BODY="$(require_func 'func perform(' "$PROJECT")"; then
  grep -q 'TimelineLinkage.follow(from: before, to: &next, deletesContent: deletesContent)' <<<"$BODY" \
    || fail "perform 收尾没调 TimelineLinkage.follow（联动就只剩拖动那一条路，删 / 变速 / 定格 / AI 全不跟）"
  grep -q 'deletesContent: Bool = false' <<<"$BODY" \
    || fail "perform 没有 deletesContent 参数：真删和裁切分不开，要么裁一下就把字幕删了、要么删了画面字幕还在"
  awk '/next.packMain\(\)/{p=NR} /TimelineLinkage.follow/{l=NR} /assignMissingTrackColors/{c=NR} END{exit !(p && l && c && p<l && l<c)}' <<<"$BODY" \
    || fail "perform 里联动的位置不对：必须在 packMain 之后（按合拢后的位置算）、assignMissingTrackColors 之前"
fi
if BODY="$(require_func 'func liveApply(' "$PROJECT")"; then
  grep -q 'TimelineLinkage.follow(from: snapshot, to: &next, deletesContent: false)' <<<"$BODY" \
    || fail "liveApply 收尾没调 TimelineLinkage.follow（裁主轨块的头尾时压在上面的东西不实时跟）或者连续编辑里真删了"
fi
# 规则（画面账、挪 / 删）只许在这两个文件里：别处再算一份「谁压在谁上面」迟早分叉。
OTHERS="$(grep -rl 'TimelineLinkage.Ledger\|static func follow(from' Sources/SrtFlow --include='*.swift' | grep -v "^${LINKAGE}$" || true)"
[ -z "$OTHERS" ] || fail "联动的画面账在 TimelineLinkage 之外又算了一份：${OTHERS}"

# ── 12b. 真删的入口说了自己是真删；裁切 / 变速 / 定格没说（它们不许删东西） ───
if BODY="$(require_func 'func deleteSelected()' "$PROJECT")"; then
  grep -q 'deletesContent: true' <<<"$BODY" || fail "⌫ 删选中没传 deletesContent: true：联动开着删一段，压在上面的字幕留在原地"
fi
if BODY="$(require_func 'static func delete(' "$AI_TIMELINE_TOOLS")"; then
  grep -q 'deletesContent: true' <<<"$BODY" || fail "AI 的 delete_items 没传 deletesContent: true"
  grep -q 'AILinkageReport.json' <<<"$BODY" || fail "delete_items 的结果里没带联动挪了 / 删了什么（AI 看不见就得再 get_timeline 一遍）"
fi
grep_code 'project.perform(deletesContent: true)' "$AI_SPEECH_CUT" \
  || fail "cut_speech 落账没传 deletesContent: true：剪掉的停顿上的东西不删"
grep_code 'project.linkageEnabled' "$AI_SPEECH_CUT" \
  || fail "cut_speech 的 next_step 没按联动开关分两种说法（关着要提醒重新生成字幕）"
COUNT="$(grep -c 'deletesContent: true' "$PROJECT" "$AI_TIMELINE_TOOLS" "$AI_SPEECH_CUT" | awk -F: '{ s += $2 } END { print s }')"
TOTAL="$(grep -rc 'deletesContent: true' Sources/SrtFlow --include='*.swift' | awk -F: '{ s += $2 } END { print s }')"
[ "$COUNT" -eq "$TOTAL" ] \
  || fail "deletesContent: true 出现在了 ⌫ / delete_items / cut_speech 之外（共 ${TOTAL} 处，认得的 ${COUNT} 处）：裁切 / 变速 / 定格不许连带删东西"

# ── 12c. 拖动计划带上压在主轨块上的东西（实时跟着画、没有障碍、不当吸附参考点） ──
for entry in 'func dragPlan(draggedID' 'func shapeDragPlan(shapeID' 'func cueDragPlan(cueID'; do
  if BODY="$(require_func "$entry" "$PROJECT")"; then
    grep -q 'linkedAttachments(of:' <<<"$BODY" || fail "${entry} 没把联动压着的东西算进这一轮（拖主轨块时字幕不跟着动）"
    grep -q '\.adding(attachments: attached)' <<<"$BODY" || fail "${entry} 没把联动压着的东西挂进计划"
    grep -q 'union(attached.ids)' <<<"$BODY" || fail "${entry} 没把联动压着的东西从吸附参考点里剔掉（跟着动的块当了别人的参考点）"
  fi
done
if BODY="$(require_func 'func linkedAttachments(of' "Sources/SrtFlow/VideoEditProject+Selection.swift")"; then
  grep -q 'guard linkageEnabled else { return .none }' <<<"$BODY" || fail "linkedAttachments 没按开关走：关着也会把压着的东西拖走"
  grep -q 'TimelineLinkage.attachments(of: hosts, in: state)' <<<"$BODY" || fail "linkedAttachments 没走 TimelineLinkage.attachments（名单只许那一份算法）"
fi
grep_code 'obstacles: \[\], kind: kind, host: item.host' "$SNAP" \
  || fail "adding(attachments:) 挂进来的成员要没有障碍、带宿主（有障碍会反过来挡住主轨块的拖动）"
if BODY="$(require_func 'private mutating func realignCompanions(' "$EDITS")"; then
  grep -q 'member.host' <<<"$BODY" || fail "realignCompanions 不按宿主的实际落点平联动成员：磁吸插空之后压着的东西和块错开一个身位"
fi

# ── 12d. 默认开、AI 的说明和结果说了联动 ────────────────────────────────
grep_code 'object\["linkage"\] = .bool(project.linkageEnabled)' "$AI_TIMELINE_TOOLS" \
  || fail "get_timeline 的结果里没报联动开关（AI 不知道删一段会不会把字幕一起删掉）"
# 措辞压得很短（清单总长度有 80,000 字的预算，docs/architecture/ai-control-mcp.md），只认「Linkage on:」这个记号。
[ "$(grep -c 'Linkage on:' "$MCP_TIMELINE")" -ge 2 ] || fail "delete_items / freeze_frame 的说明没写联动开着时别的轨跟着动（要两处「Linkage on:」）"
grep_code 'Linkage on:' "$MCP_SMART" || fail "cut_speech 的说明没写联动开着时压在片段上的东西跟着它的碎片走"
