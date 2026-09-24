#!/usr/bin/env bash
# checks/timeline-drag-wiring.sh 的一节：点非素材处 = 把播放头挪过来（2026-09-21 用户拍板）。
#
# **不单独跑**：由 timeline-drag-wiring.sh 用 `source` 装进来，共用它的 fail / grep_code /
# require_func / extract_func 和路径变量（VIEW …）。拆出来是因为主文件超过了单文件上限、
# 只许降不许涨（docs/architecture/coding-standards.md）。

# ── 点非素材处 = 把播放头挪过来（2026-09-21 用户拍板） ─────────────────
# 在这之前，播放头只能在 26pt 高的标尺上点出来。合同是：
#   点空白 → 移播放头**并且**清空选择；按住拖 → 还是框选（两者靠 4pt 门槛分开）。
# 「非素材处」不用自己判：块本体 / 标尺 / 把手 / 标记帽子各有自己的手势，
# SwiftUI 里子视图优先，落到容器上的只剩谁都不认领的空白。
if BODY="$(require_func 'private var scrolledContent: some View' "$VIEW")"; then
  grep -q 'onTapGesture(coordinateSpace: \.local)' <<<"$BODY" \
    || fail "点空白的手势没带 coordinateSpace: .local：拿不到落点，播放头不知道该挪到哪一刻"
  grep -q 'seekFromTimeline(time: location\.x / pps' <<<"$BODY" \
    || fail "点空白没把播放头挪过去（少了 seekFromTimeline）"
  grep -q 'project\.clearSelection()' <<<"$BODY" \
    || fail "点空白不再清空选择：界面上就没有任何地方能取消选中了"
fi
# 夹紧只能有一处：标尺和点空白各写一份 min/max 迟早分叉（一边夹到片尾、一边不夹，
# 点右边那片空白就会把播放头送到工程之外，工具栏上一排按钮随即全灰）。
if BODY="$(require_func 'func seekFromTimeline(' "$VIEW")"; then
  grep -q 'min(max(0, time), project.duration)' <<<"$BODY" \
    || fail "seekFromTimeline 没把落点夹进 [0, duration]"
fi
grep_code 'seekFromTimeline(time: time, precise: precise)' "$VIEW" \
  || fail "标尺的 onSeek 没走 seekFromTimeline：夹紧会变成两份账"
CLAMPS="$(grep -c 'clock\.seek(to: min(max(0' "$VIEW" || true)"
[ "$CLAMPS" -le 1 ] \
  || fail "$VIEW 里有 ${CLAMPS} 处自己夹紧后 seek：落点只许 seekFromTimeline 一处算"
