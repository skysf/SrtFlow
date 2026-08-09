#!/usr/bin/env bash
# 扫描守卫：剪辑/形状拖动手势的接线约束。
#
# 这些都是「纯函数全对、接线接错就整个白搭」的类型，自检编不动 @MainActor 的
# SwiftUI 视图，只能在源码层面钉住（同 PR#22 复审那条接线守卫的做法）。
# 落点本身的正确性由 scripts/check-timeline-snap.sh 管。
#
# 背景见 docs/bugfixes/2026-08-09-timeline-clip-drag-lag-and-alignment.md
# 与 docs/architecture/timeline-drag-gestures.md。
set -euo pipefail
cd "$(dirname "$0")/.."

VIEW="Sources/SrtFlow/VideoEditTimelineView.swift"
PROJECT="Sources/SrtFlow/VideoEditProject.swift"
EDITS="Sources/SrtFlow/VideoEditTimelineEdits.swift"
SNAP="Sources/SrtFlow/VideoEditTimelineSnap.swift"
DRAG="Sources/SrtFlow/VideoEditTimelineDrag.swift"
FAILED=0

fail() {
  echo "✗ $1" >&2
  FAILED=1
}

# 取一个方法的函数体（签名行 → 第一条 4 空格缩进的收尾大括号）。
extract_func() {
  awk -v pat="$1" '
    index($0, pat) { inside = 1 }
    inside { print }
    inside && /^    \}$/ { exit }
  ' "$2"
}

require_func() {
  local body
  body="$(extract_func "$1" "$2")"
  if [ -z "$body" ]; then
    fail "找不到 $1（在 $2），接线守卫失去目标 —— 改名了就同步改这里"
    return 1
  fi
  printf '%s\n' "$body"
}

# ── 1. 正在被拖 / 被裁的块必须豁免那条 0.12s 重排动画 ─────────────────
# 漏掉任一半，块画出来的就是「低通滤波后的鼠标」——手越快落后越多。
ANIM="$(grep -n '\.animation(.*value: clip\.timelineStart' "$VIEW" || true)"
if [ -z "$ANIM" ]; then
  fail "找不到剪辑块那条 .animation(..., value: clip.timelineStart)，接线守卫失去目标"
else
  echo "$ANIM" | grep -q 'isTrimming' || fail "剪辑块的 .animation 没豁免裁切中的块（isTrimming）：$ANIM"
  echo "$ANIM" | grep -q 'dragOffset' || fail "剪辑块的 .animation 没豁免拖动中的块（dragOffset）：$ANIM"
fi

# ── 2. 拖动过程中一个字都不许写进 TimelineState ────────────────────────
# 每一拍改 state 会连带整个编辑器视图树重建 + 重挂自动保存，mouseDragged
# 随即积压，块就追不上光标了。
if UPDATE_BODY="$(require_func 'private func updateClipDrag' "$VIEW")"; then
  for forbidden in 'liveApply' 'liveMove' 'commitDrag' 'commitShapeDrag' 'relocate' 'project.perform'; do
    printf '%s\n' "$UPDATE_BODY" | grep -q "$forbidden" \
      && fail "updateClipDrag 里出现了 ${forbidden}：拖动中禁止写 TimelineState"
  done
  # 候选/障碍必须在手势开始时冻住：拖动中重算 = 跟着动的伙伴又变回参考点（粘手）。
  printf '%s\n' "$UPDATE_BODY" | grep -q 'snapCandidates\|TimelineSnap.candidates\|dragPlan(' \
    && fail "updateClipDrag 里重算了冻结输入：候选/障碍只能在 begin 时取一次"
fi

# ── 3. 一轮拖动的输入必须在手势开始时冻结 ──────────────────────────────
for entry in 'private func beginClipDrag' 'private func beginShapeDrag'; do
  if BODY="$(require_func "$entry" "$VIEW")"; then
    printf '%s\n' "$BODY" | grep -q '[dD]ragPlan(' \
      || fail "${entry} 没有冻结这一轮的输入（dragPlan/shapeDragPlan）"
  fi
done
if BODY="$(require_func 'func dragPlan(draggedID' "$PROJECT")"; then
  printf '%s\n' "$BODY" | grep -q 'snapCandidates' \
    || fail "dragPlan 没有取吸附候选：那这一轮拖动根本不会吸附"
  printf '%s\n' "$BODY" | grep -q 'ClipDragPlan.make' \
    || fail "dragPlan 没走纯值的 ClipDragPlan.make：那份逻辑自检就够不着了"
fi
# 障碍必须排除跟着一起动的块（否则整组被自己人挡住 = 拖不动）。
if BODY="$(require_func 'static func make(' "$SNAP")"; then
  printf '%s\n' "$BODY" | grep -q 'filter { !movingIDs.contains' \
    || fail "ClipDragPlan.make 的障碍没排除跟着动的块"
fi

# ── 4. 落点只有一份算法 ────────────────────────────────────────────────
# 拖动中渲染和松手落地都必须来自同一份 DragResolution。commit 里再算一遍
#（历史上是 clampedStart）就会「拖动中显示 9s、松手弹到 5s」。
for entry in 'func commitDrag' 'func commitShapeDrag'; do
  if BODY="$(require_func "$entry" "$PROJECT")"; then
    # 一步撤销：整个落地收在**一次** perform 里（跨轨搬运也得在同一次里）。
    COUNT="$(printf '%s\n' "$BODY" | grep -c 'perform(\|perform {' || true)"
    [ "$COUNT" -eq 1 ] || fail "${entry} 里有 ${COUNT} 处 perform，应当正好 1 处（一步撤销）"
  fi
done
# 状态变换本身留在纯值层，自检才够得着。
if BODY="$(require_func 'mutating func applyDrag' "$EDITS")"; then
  printf '%s\n' "$BODY" | grep -q 'clampedStart' \
    && fail "applyDrag 里又「挤开」了一次：位置只能来自拖动中那份 DragResolution"
  printf '%s\n' "$BODY" | grep -q 'TimelineSnap\.resolve\|resolve(desiredDelta' \
    && fail "applyDrag 里又解析了一遍落点：只能用传进来的 resolution"
  printf '%s\n' "$BODY" | grep -q 'for member in plan.members' \
    || fail "applyDrag 没有整组平移：跟随块会被落在旧时刻（A/V 错位）"
  printf '%s\n' "$BODY" | grep -q 'resolution.delta' \
    || fail "applyDrag 没有用整组统一的 resolution.delta"
  printf '%s\n' "$BODY" | grep -q 'resolution.mainInsertion' \
    || fail "applyDrag 没有用拖动中算好的 mainInsertion：主轨插入指示线会说谎"
fi

# ── 5. 移动手势必须钉在不会动的参照系上 ────────────────────────────────
# 块自己会在手指底下挪窝（.offset），边缘自动滚动还会把整块内容抽走，
# 两者都会污染以块自身为参照的 translation。
# 光查「有没有写 coordinateSpace:」是假绿 —— 写成 .local 一样能绿。
GESTURE="$(grep -n 'DragGesture(minimumDistance: 4' "$VIEW" || true)"
if [ -z "$GESTURE" ]; then
  fail "找不到块的移动手势，接线守卫失去目标"
else
  while IFS= read -r line; do
    printf '%s\n' "$line" | grep -q 'coordinateSpace: \.named(VideoEditTimelineView\.scrollSpace)' \
      || fail "移动手势没钉在滚动视口坐标系上：$line"
  done <<< "$GESTURE"
fi

# ── 6. 缩放只有一个会夹范围的入口 ──────────────────────────────────────
# pps 掉到 1 以下时，位移换算会被 max(pps, 1) 兜底，1:1 跟手当场坏掉。
grep -n 'pixelsPerSecond.wrappedValue = ' "$VIEW" | grep -vq 'clamped' \
  && fail "捏合直接给 pixelsPerSecond 赋了未夹的值"
grep -rn 'project.pixelsPerSecond = \|pixelsPerSecond = min(\|pixelsPerSecond = max(' Sources/SrtFlow/VideoEditView.swift \
  && fail "工具栏绕开了 setPixelsPerSecond 这个唯一缩放入口"

# ── 7. 自动滚动的心跳必须有取消兜底 ────────────────────────────────────
grep -q 'deinit' "$DRAG" || fail "TimelineAutoScroller 没有 deinit 兜底，timer 可能永远留在 RunLoop 上"
grep -q 'dismantleNSView' "$DRAG" || fail "滚动视图参照物没有 dismantleNSView：视图树拆掉后心跳还在跑"
grep -q 'onDisappear' "$VIEW" || fail "时间线没有 onDisappear：视图消失时自动滚动不会停"

if [ "$FAILED" -ne 0 ]; then
  exit 1
fi
echo "✓ timeline-drag-wiring：动画豁免 / 拖动中不写 state / 输入冻结 / 落点单一 / 手势坐标系 / 缩放钳制 / 心跳兜底"
