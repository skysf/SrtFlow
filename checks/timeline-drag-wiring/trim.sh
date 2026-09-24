#!/usr/bin/env bash
# checks/timeline-drag-wiring.sh 的一节：裁切 —— 链接伙伴一起裁、选中的一组一起裁（2026-09-25）。
#
# **不单独跑**：由 timeline-drag-wiring.sh 用 `source` 装进来，共用它的 fail / grep_code /
# require_func 和路径变量。纯值那一半（范围、整组一起停）在 scripts/check-timeline-snap.sh
# 第 1b 组；这里钉接线：把手的裁切必须经 `trimGroup`，名单必须带上链接伙伴。
# 案例 docs/bugfixes/2026-09-25-trim-ignores-linked-clips.md；
# 合同 docs/architecture/timeline-drag-gestures.md「3.6 多段一起裁」。

TRIM="Sources/SrtFlow/VideoEditTimelineTrim.swift"
[ -f "$TRIM" ] || fail "文件不在：$TRIM"
# 1) 剪辑的把手裁切要带上链接伙伴，且整组走 trimGroup（整组一起停）。
if BODY="$(require_func 'func liveTrim(' "$PROJECT")"; then
  grep -q 'linkedClipIDs(of: id)' <<<"$BODY" \
    || fail "liveTrim 没带上链接伙伴（linkedClipIDs）：视频裁了、链接的音频留在原长"
  grep -q 'state.trimGroup(' <<<"$BODY" \
    || fail "liveTrim 没走 trimGroup：链接伙伴各裁各的，短的那段到头了长的还在走"
  for forbidden in 'clip.sourceStart +=' 'clip.sourceDuration +=' 'clip.sourceDuration -='; do
    grep -qF "$forbidden" <<<"$BODY" && fail "liveTrim 里又自己改素材范围了（${forbidden}）：裁切的算法只许有 TimelineTrim 一份"
  done
fi
# 2) 裁的算法只有一份：素材范围只在 TimelineTrim 里改。豁免：转场借余料那份**渲染副本**
#    （VideoEditTransitionHandles.swift，只在展开函数里改、不进用户状态，见 transition-handles.md）。
TRIM_MATH="$(grep -rn 'sourceDuration -= \|sourceDuration += ' Sources/SrtFlow --include='*.swift' \
  | grep -v '^[^:]*:[0-9]*:[[:space:]]*//' | grep -v "$TRIM" | grep -v 'VideoEditTimelineEdits.swift' \
  | grep -v 'VideoEditModels.swift' | grep -v 'VideoEditTransitionHandles.swift' || true)"
[ -z "$TRIM_MATH" ] || fail "裁切的素材范围算法只许在 $TRIM 里：$TRIM_MATH"
