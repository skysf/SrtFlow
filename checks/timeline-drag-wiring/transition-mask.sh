#!/usr/bin/env bash
# checks/timeline-drag-wiring.sh 的一节：接缝上的转场遮罩。
#
# **不单独跑**：由 timeline-drag-wiring.sh 用 `source` 装进来，共用它的 fail / grep_code /
# require_func 和路径变量（VIEW、MASK …）。拆出来是因为主文件超过了单文件上限、只许降不许涨。

# ── 接缝上的转场遮罩 ──────────────────────────────────────────────────
# 遮罩是改转场时长的**第二条路**（第一条是检查器的滑块）。三件事必须接住：
# 行首锚点不能省：不带锚点时 `XXTransitionMaskView(` 也会命中，改名照样假绿
# （反向验证第一版就是这么漏过去的）。
grep_code '^ *TransitionMaskView(' "$VIEW" \
  || fail "主轨那一行没有挂 TransitionMaskView：接缝上的转场遮罩根本不会出现"

# 拖动开始时把时长定死。改时长会让磁吸重排片段、窗口跟着挪，每一拍拿**实时**
# 窗口去算增量就是自己追自己（手越拖越飘）——和剪辑块 dragOrigin 同一条纪律。
if MASK_EDGE="$(require_func 'private func edge(' "$MASK")"; then
  grep -q 'dragStartDuration == nil' <<<"$MASK_EDGE" \
    || fail "转场遮罩的拖动没有在开始时定死时长（dragStartDuration）：磁吸重排会让它自己追自己"
fi

# 落值必须被容量夹住。拖得出一个渲染管线做不出来的时长，就又回到了
# 「设了但成片里没有」——那正是 2026-09-20 那次事故的形状。
if MASK_APPLY="$(require_func 'private func apply(duration:' "$MASK")"; then
  grep -q 'maxDuration' <<<"$MASK_APPLY" \
    || fail "转场遮罩落值时没有按容量夹紧：能拖出渲染管线做不出来的时长"
fi
