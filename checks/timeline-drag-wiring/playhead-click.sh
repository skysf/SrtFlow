#!/usr/bin/env bash
# checks/timeline-drag-wiring.sh 的一节：点非素材处（2026-09-21）/ 点块本体（2026-09-30）= 把播放头挪过来。
#
# **不单独跑**：由 timeline-drag-wiring.sh 用 `source` 装进来，共用它的 fail / grep_code /
# require_func / extract_func 和路径变量（VIEW、CLIP_BLOCK、SHAPE_ROW、TEXT_ROW、SUBTITLE_ROW、
# CUE_BLOCK、MASK …）。拆出来是因为主文件超过了单文件上限、只许降不许涨
#（docs/architecture/coding-standards.md）。合同：docs/architecture/timeline-drag-gestures.md §5f。

# ── 点非素材处 = 把播放头挪过来（2026-09-21 用户拍板） ─────────────────
# 在这之前，播放头只能在 26pt 高的标尺上点出来。合同是：
#   点空白 → 移播放头**并且**清空选择；按住拖 → 还是框选（两者靠 4pt 门槛分开）。
# 「非素材处」不用自己判：块本体 / 标尺 / 把手 / 标记帽子各有自己的手势，
# SwiftUI 里子视图优先，落到容器上的只剩谁都不认领的空白。
if BODY="$(require_func 'private var scrolledContent: some View' "$VIEW")"; then
  grep -q 'onTapGesture(coordinateSpace: \.local)' <<<"$BODY" \
    || fail "点空白的手势没带 coordinateSpace: .local：拿不到落点，播放头不知道该挪到哪一刻"
  grep -q 'project\.seekFromTimeline(time: location\.x / pps' <<<"$BODY" \
    || fail "点空白没把播放头挪过去（少了 project.seekFromTimeline）"
  grep -q 'project\.clearSelection()' <<<"$BODY" \
    || fail "点空白不再清空选择：界面上就没有任何地方能取消选中了"
fi
grep_code 'project\.seekFromTimeline(time: time, precise: precise)' "$VIEW" \
  || fail "标尺的 onSeek 没走 project.seekFromTimeline：夹紧会变成两份账"

# ── 夹紧只能有一处：工程上的 seekFromTimeline（2026-09-30 从时间线视图搬过去） ────────
# 标尺和点空白各写一份 min/max 迟早分叉（一边夹到片尾、一边不夹，点右边那片空白就会把播放头
# 送到工程之外，工具栏上一排按钮随即全灰）。纯值那一半在 TimelineSeek（自检 checks/TimelineSnap/Seek.swift）。
SEEK_ENTRY="Sources/SrtFlow/VideoEditProject+Seek.swift"
SEEK_RULE="Sources/SrtFlow/VideoEditTimelineSeek.swift"
FILTER_ROW="Sources/SrtFlow/VideoEditTimelineFilterRow.swift"
for f in "$SEEK_ENTRY" "$SEEK_RULE" "$FILTER_ROW"; do
  [ -f "$f" ] || fail "文件不在：$f"
done
if BODY="$(require_func 'func seekFromTimeline(time: Double' "$SEEK_ENTRY")"; then
  grep -q 'TimelineSeek\.clamped(time, duration: duration)' <<<"$BODY" \
    || fail "seekFromTimeline 没经 TimelineSeek.clamped 夹进 [0, duration]"
fi
if BODY="$(require_func 'static func clamped(' "$SEEK_RULE")"; then
  grep -q 'min(max(0, time), max(0, duration))' <<<"$BODY" \
    || fail "TimelineSeek.clamped 不是 [0, duration] 的夹紧"
fi
if BODY="$(require_func 'func seekFromTimeline(blockX' "$SEEK_ENTRY")"; then
  grep -q 'TimelineSeek\.timeInBlock(' <<<"$BODY" \
    || fail "点在块上的落点没经 TimelineSeek.timeInBlock（要落在指针底下、不出这一块）"
  grep -q 'seekFromTimeline(time:' <<<"$BODY" \
    || fail "点在块上的入口没转交给 seekFromTimeline(time:)：夹紧又成两份账"
fi
# 整个时间线这一族一处都不许自己 clock.seek：落点只许经工程的入口算（注释里提到不算）。
SEEKS="$(grep -n 'clock\.seek(' Sources/SrtFlow/VideoEditTimeline*.swift | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' | grep -c . || true)"
[ "$SEEKS" -eq 0 ] \
  || fail "时间线这一族里有 ${SEEKS} 处自己 clock.seek：落点只许经 project.seekFromTimeline 一处算（连夹紧一起）"
ENTRY_SEEKS="$(grep -c 'clock\.seek(' "$SEEK_ENTRY" || true)"
[ "$ENTRY_SEEKS" -eq 1 ] \
  || fail "$SEEK_ENTRY 里 clock.seek 有 ${ENTRY_SEEKS} 处，只许 seekFromTimeline(time:) 那一处"

# ── 点块本体 = 选中 + 播放头落到指针底下（2026-09-30 用户拍板） ────────────────────
# 八条一起定的：所有块都跟（剪辑 / 文字 / 形状 / 滤镜 / 字幕句 / 转场遮罩）、落在指针底下、
# ⌘ / ⇧ 加选不动、拖动不动（拖走的是 DragGesture，不经点击）、刀片切完落到刀口、
# 双击的第一下照样动、播放中照样 seek 接着播、不留「只选中不动播放头」的出口。
#
# 每一种块：点击手势带 coordinateSpace: .local、落点经 seekFromTimeline(blockX:)，
# 且加选时跳过（`if !additive`）。指针的 x 是块自己坐标系里的，所以读它的 onTapGesture 必须挂在
# 块的 `.offset(` **之前**（几何效果只挪画面不挪布局框，同把手 / `.contentShape` 那条）。
# 格式：<块视图所在文件>|<块名>|<接落点的文件（行或块自己）>|<块的 offset 那一行的特征>
block_tap_before_offset() {
  local file="$1" label="$2" offset_pat="$3" tap offset
  tap="$(grep -n 'onTapGesture(coordinateSpace: \.local)' "$file" | head -1 | cut -d: -f1)"
  offset="$(grep -n "$offset_pat" "$file" | head -1 | cut -d: -f1)"
  [ -n "$tap" ] || { fail "${label}：点击手势没带 coordinateSpace: .local，拿不到指针在块里的 x"; return; }
  [ -n "$offset" ] || { fail "${label}：找不到块的 .offset（特征 ${offset_pat}），守卫失去目标 —— 改了就同步这里"; return; }
  [ "$tap" -lt "$offset" ] \
    || fail "${label}：读落点的 onTapGesture（第 ${tap} 行）挂在 .offset（第 ${offset} 行）之后 —— 读到的不是块自己的坐标"
}
for spec in \
  "$CLIP_BLOCK|剪辑块|$CLIP_BLOCK|\.offset(x: (clip\.timelineStart" \
  "$SHAPE_ROW|形状块|$SHAPE_ROW|\.offset(x: (shape\.timelineStart" \
  "$TEXT_ROW|文字块|$TEXT_ROW|\.offset(x: (overlay\.timelineStart" \
  "$FILTER_ROW|滤镜块|$FILTER_ROW|x: (filter\.timelineStart" \
  "$CUE_BLOCK|字幕句|$SUBTITLE_ROW|x: (cue\.start" \
  "$MASK|转场遮罩|$MASK|\.offset(x: rect\.x"; do
  IFS='|' read -r file label host offset_pat <<<"$spec"
  block_tap_before_offset "$file" "$label" "$offset_pat"
  grep_code 'seekFromTimeline(blockX:' "$host" \
    || fail "${label}：点了不移播放头（${host} 里少了 seekFromTimeline(blockX:)）"
done
# 加选不动：五种可加选的块，seekFromTimeline(blockX:) 前面那一行必须是 `if !additive {`。
for host in "$CLIP_BLOCK" "$SHAPE_ROW" "$TEXT_ROW" "$FILTER_ROW" "$SUBTITLE_ROW"; do
  grep -B1 'seekFromTimeline(blockX:' "$host" | grep -c 'if !additive {' >/dev/null \
    || fail "${host}：⌘ / ⇧ 加选时播放头也跟着跳（seekFromTimeline(blockX:) 没包在 if !additive 里）"
done
# 刀片：切完落到刀口。
if BODY="$(extract_func '.onTapGesture(coordinateSpace: .local) { location in' "$CLIP_BLOCK")"; then
  grep -q 'project\.splitClip(clip\.id, at: cut)' <<<"$BODY" \
    || fail "剪辑块的刀片不再在点的位置切"
  grep -q 'project\.seekFromTimeline(time: cut)' <<<"$BODY" \
    || fail "刀片切完播放头没落到刀口"
fi
# 双击文字跳到起点那一下也走同一个入口。
grep_code 'project\.seekFromTimeline(time: overlay\.timelineStart)' "$TEXT_ROW" \
  || fail "双击文字跳到起点没走 project.seekFromTimeline"
