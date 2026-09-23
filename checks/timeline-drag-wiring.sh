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

# 时间线视图在 2026-09-18 按职责拆成了一族文件（拆分前单文件 2101 行）。
# 每条检查都钉在**它该在的那个文件**上：路径写错 = 守卫扫了个空文件还是绿的，
# 所以下面先逐个确认文件在，缺一个立刻红。
VIEW="Sources/SrtFlow/VideoEditTimelineView.swift"
MARQUEE_VIEW="Sources/SrtFlow/VideoEditTimelineMarqueeGesture.swift"
DRAG_WIRING="Sources/SrtFlow/VideoEditTimelineDragWiring.swift"
CLIP_BLOCK="Sources/SrtFlow/VideoEditTimelineClipBlock.swift"
SHAPE_ROW="Sources/SrtFlow/VideoEditTimelineShapeRow.swift"
TEXT_ROW="Sources/SrtFlow/VideoEditTimelineTextRow.swift"
SUBTITLE_ROW="Sources/SrtFlow/VideoEditTimelineSubtitleRow.swift"
RULER="Sources/SrtFlow/VideoEditTimelineRuler.swift"
THUMBS="Sources/SrtFlow/VideoEditTimelineThumbnails.swift"
WAVEFORM="Sources/SrtFlow/VideoEditTimelineWaveform.swift"
ZOOM="Sources/SrtFlow/VideoEditTimelinePinchZoom.swift"
GEOMETRY="Sources/SrtFlow/VideoEditTimelineScrollGeometry.swift"
HEADER_COLUMN="Sources/SrtFlow/VideoEditTimelineHeaderColumn.swift"
ROW_HEIGHTS="Sources/SrtFlow/VideoEditTimelineRowHeights.swift"
ROW_HEIGHT_DRAG="Sources/SrtFlow/VideoEditTimelineRowHeightDrag.swift"
# 「整族都必须满足」的约束（手势坐标系、文件体积）扫这一批。
MASK="Sources/SrtFlow/VideoEditTimelineTransitionMask.swift"
DROP_ROUTER="Sources/SrtFlow/VideoEditTimelineDropRouter.swift"
VOLUME_CURVE="Sources/SrtFlow/VideoEditTimelineVolumeCurve.swift"
TIMELINE_VIEWS=("$VIEW" "$MARQUEE_VIEW" "$DRAG_WIRING" "$CLIP_BLOCK" "$SHAPE_ROW" \
  "$TEXT_ROW" "$SUBTITLE_ROW" "$RULER" "$THUMBS" "$WAVEFORM" "$ZOOM" "$GEOMETRY" \
  "$HEADER_COLUMN" "$ROW_HEIGHTS" "$ROW_HEIGHT_DRAG" "$MASK" "$DROP_ROUTER" "$VOLUME_CURVE")
PROJECT="Sources/SrtFlow/VideoEditProject.swift"
EDITS="Sources/SrtFlow/VideoEditTimelineEdits.swift"
SNAP="Sources/SrtFlow/VideoEditTimelineSnap.swift"
DRAG="Sources/SrtFlow/VideoEditTimelineDrag.swift"
ROW_SELECT_ENTRY="Sources/SrtFlow/VideoEditProject+RowSelection.swift"
ROW_SELECT_RULE="Sources/SrtFlow/VideoEditTimelineRowSelection.swift"
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

# 只看**真代码行**：注释里写了同一串不算接上了（第 10 节反向验证时踩过一次
# 假绿 —— 文件头的说明文字里正好有那行代码的样子）。
grep_code() {
  grep -n "$1" "$2" | grep -vE '^[0-9]+:[[:space:]]*//' | grep -c . >/dev/null
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

# ── 0. 拆分后的文件都必须在，且都不许再长回「什么都往里塞」的那种体积 ──
# 这一族本来是一个 2101 行的文件，谁都不敢动。拆完之后守卫得自己盯住两件事：
# 路径别失效（扫空文件 = 假绿），单文件别再超过仓库约 800 行的警戒线。
for file in "${TIMELINE_VIEWS[@]}"; do
  if [ ! -f "${file}" ]; then
    fail "找不到 ${file}：时间线视图这一族的文件被改名/删了，守卫会扫空 —— 同步改这里"
    continue
  fi
  LINES="$(wc -l < "${file}" | tr -d ' ')"
  [ "${LINES}" -le 800 ] \
    || fail "${file} 已经 ${LINES} 行，超过 800 行警戒线：按职责再拆一刀，别让它长回老样子"
done

# ── 1. 正在被拖 / 被裁的块必须豁免那条 0.12s 重排动画 ─────────────────
# 漏掉任一半，块画出来的就是「低通滤波后的鼠标」——手越快落后越多。
ANIM="$(grep -n '\.animation(.*value: clip\.timelineStart' "$CLIP_BLOCK" || true)"
if [ -z "$ANIM" ]; then
  fail "找不到剪辑块那条 .animation(..., value: clip.timelineStart)，接线守卫失去目标"
else
  grep -q 'isTrimming' <<<"$ANIM" || fail "剪辑块的 .animation 没豁免裁切中的块（isTrimming）：$ANIM"
  grep -q 'dragOffset' <<<"$ANIM" || fail "剪辑块的 .animation 没豁免拖动中的块（dragOffset）：$ANIM"
fi

# ── 2. 拖动过程中一个字都不许写进 TimelineState ────────────────────────
# 每一拍改 state 会连带整个编辑器视图树重建 + 重挂自动保存，mouseDragged
# 随即积压，块就追不上光标了。
if UPDATE_BODY="$(require_func 'func updateClipDrag' "$DRAG_WIRING")"; then
  for forbidden in 'liveApply' 'liveMove' 'commitDrag' 'commitFreeDrag' 'relocate' 'project.perform'; do
    grep -q "$forbidden" <<<"$UPDATE_BODY" \
      && fail "updateClipDrag 里出现了 ${forbidden}：拖动中禁止写 TimelineState"
  done
  # 候选/障碍必须在手势开始时冻住：拖动中重算 = 跟着动的伙伴又变回参考点（粘手）。
  grep -q 'snapCandidates\|TimelineSnap.candidates\|dragPlan(' <<<"$UPDATE_BODY" \
    && fail "updateClipDrag 里重算了冻结输入：候选/障碍只能在 begin 时取一次"
fi

# ── 3. 一轮拖动的输入必须在手势开始时冻结 ──────────────────────────────
for entry in 'func beginClipDrag' 'func beginShapeDrag' 'func beginCueDrag'; do
  if BODY="$(require_func "$entry" "$DRAG_WIRING")"; then
    grep -q '[dD]ragPlan(' <<<"$BODY" \
      || fail "${entry} 没有冻结这一轮的输入（dragPlan/shapeDragPlan）"
  fi
done
# 三个入口的「跟着动的名单」必须都走那份纯值规则：链接组要为**每一个**多选
# 成员各展开一次（只展开被拖的那个 = 另一段的音频留在原地，A/V 错位），
# 磁吸下主轨成员要整批剔除（平了也会被 packMain 排回去 = 拖动中骗人）。
for entry in 'func movingClipIDs(draggedID' 'func shapeDragPlan(shapeID' 'func cueDragPlan(cueID'; do
  if BODY="$(require_func "$entry" "$PROJECT")"; then
    grep -q 'draggingClipIDs(' <<<"$BODY" \
      || fail "${entry} 没走 TimelineState.draggingClipIDs：链接组/磁吸剔除的规则会各写一份"
    grep -q 'linkedClipIDs(' <<<"$BODY" \
      && fail "${entry} 自己展开了链接组：规则只能有一份（draggingClipIDs）"
  fi
done
if BODY="$(require_func 'func draggingClipIDs(' "$EDITS")"; then
  grep -q 'for id in seed' <<<"$BODY" \
    || fail "draggingClipIDs 没有为每一个多选成员展开链接组：另一段的音频会留在原地"
  grep -q 'magnetPinsMainTrack' <<<"$BODY" \
    || fail "draggingClipIDs 丢了磁吸剔除主轨成员那条"
fi
if BODY="$(require_func 'func dragPlan(draggedID' "$PROJECT")"; then
  grep -q 'snapCandidates' <<<"$BODY" \
    || fail "dragPlan 没有取吸附候选：那这一轮拖动根本不会吸附"
  grep -q 'ClipDragPlan.make' <<<"$BODY" \
    || fail "dragPlan 没走纯值的 ClipDragPlan.make：那份逻辑自检就够不着了"
fi
# 障碍必须排除跟着一起动的块（否则整组被自己人挡住 = 拖不动）。
if BODY="$(require_func 'static func make(' "$SNAP")"; then
  grep -q 'filter { !movingIDs.contains' <<<"$BODY" \
    || fail "ClipDragPlan.make 的障碍没排除跟着动的块"
fi

# ── 4. 落点只有一份算法 ────────────────────────────────────────────────
# 拖动中渲染和松手落地都必须来自同一份 DragResolution。commit 里再算一遍
#（历史上是 clampedStart）就会「拖动中显示 9s、松手弹到 5s」。
for entry in 'func commitDrag' 'func commitFreeDrag'; do
  if BODY="$(require_func "$entry" "$PROJECT")"; then
    # 一步撤销：整个落地收在**一次** perform 里（跨轨搬运也得在同一次里）。
    COUNT="$(printf '%s\n' "$BODY" | grep -c 'perform(\|perform {' || true)"
    [ "$COUNT" -eq 1 ] || fail "${entry} 里有 ${COUNT} 处 perform，应当正好 1 处（一步撤销）"
  fi
done
# 状态变换本身留在纯值层，自检才够得着。
if BODY="$(require_func 'mutating func applyDrag' "$EDITS")"; then
  grep -q 'clampedStart' <<<"$BODY" \
    && fail "applyDrag 里又「挤开」了一次：位置只能来自拖动中那份 DragResolution"
  grep -q 'TimelineSnap\.resolve\|resolve(desiredDelta' <<<"$BODY" \
    && fail "applyDrag 里又解析了一遍落点：只能用传进来的 resolution"
  grep -q 'move(plan.members' <<<"$BODY" \
    || fail "applyDrag 没有整组平移：跟随块会被落在旧时刻（A/V 错位）"
  grep -q 'resolution.delta' <<<"$BODY" \
    || fail "applyDrag 没有用整组统一的 resolution.delta"
  grep -q 'resolution.mainInsertion' <<<"$BODY" \
    || fail "applyDrag 没有用拖动中算好的 mainInsertion：主轨插入指示线会说谎"
  # 落点可能不等于 resolution.delta（磁吸插空、跨轨到岸让位），伙伴必须按
  # **实际**位移再平一次，否则整组相对位置被拆散、链接音频当场 A/V 错位。
  grep -q 'realignCompanions' <<<"$BODY" \
    || fail "applyDrag 没有按实际落点重平伙伴：跨轨/磁吸落地会拆散整组"
  # 磁吸重排必须在 applyDrag 里做完：perform 之后还会排一次，这里不排的话
  # 自检在纯值层看到的就不是最终位置（复审指出的假绿）。
  grep -q 'if magnet { packMain() }' <<<"$BODY" \
    || fail "applyDrag 没有在磁吸时自己 packMain：自检看到的落点不是最终落点"
fi
if BODY="$(require_func 'private mutating func realignCompanions' "$EDITS")"; then
  grep -q 'plan.draggedSpan.start' <<<"$BODY" \
    || fail "realignCompanions 没按「被拖块实际落点 - 冻结起点」算位移"
  grep -q 'Set(mainClips.map' <<<"$BODY" \
    || fail "realignCompanions 没把磁吸下的主轨成员排除：它们由 packMain 定位"
  # 被 packMain 排走的主轨块，它的链接伙伴要跟着**它**走，不是跟着整组的 delta。
  # 少了这条：把一段主轨块拖去别的轨，磁吸合拢主轨，留下的视频挪了、它分离出来的
  # 音频没挪 —— 声画错开一整段。
  grep -q 'linkedClipIDs(' <<<"$BODY" \
    || fail "realignCompanions 没让链接伙伴跟随被排走的主轨块：跨轨会声画错位"
fi
# 跨轨到岸让位不许把整组顶过下界（伙伴会各自被 max(0,…) 夹住，相对错位压扁）。
if BODY="$(require_func 'mutating func applyDrag' "$EDITS")"; then
  grep -q 'groupLowerDelta' <<<"$BODY" \
    || fail "applyDrag 跨轨落地没传整组下界：往左让位会压扁相对错位"
fi
if BODY="$(require_func 'func clampedStart(' "$EDITS")"; then
  grep -q 'notBefore' <<<"$BODY" \
    || fail "clampedStart 没有下界参数：跨轨让位会越过整组能去的最左边"
fi

# ── 4b. 三类成员共用同一个位移，且写第二次必须幂等 ─────────────────────
# 框选能一次选中剪辑 + 形状 + 字幕 cue。三类改的字段不同，位移只能有一个；
# 落点一律按「冻结的 span + delta」算**绝对值** —— 磁吸主轨那条分支会拿实际
# 落点把非主轨成员再平一次，叠加式的写法在那里就是双倍位移。
if BODY="$(require_func 'private mutating func move(' "$EDITS")"; then
  grep -q 'member.span.start + delta' <<<"$BODY" \
    || fail "move 没按「冻结 span + delta」算绝对落点：磁吸那条分支会变成双倍位移"
  for kind in '.clip' '.shape' '.subtitleCue'; do
    grep -q "case ${kind}" <<<"$BODY" \
      || fail "move 漏了 ${kind} 这一类成员：框选中的它不会跟着一起动"
  done
  grep -q 'LinkedSubtitleEditing.setStarts' <<<"$BODY" \
    || fail "字幕 cue 没走两轨同步的合同：译文会留在旧时刻"
fi

# ── 4c. 框选：拖框过程中一个字都不许写进 project ───────────────────────
# 和拖块同一条约束。每一拍写 @Published 的选择会连带预览区、检查器、所有块
# 连同缩略图与波形重建，还要重挂一次自动保存，框立刻跟不上光标。
for entry in 'private func updateMarquee' 'private func applyMarqueePoint'; do
  if BODY="$(require_func "$entry" "$MARQUEE_VIEW")"; then
    for forbidden in 'applyBoxSelection' 'project.select' 'clearSelection' 'project.perform' 'liveApply'; do
      grep -q "$forbidden" <<<"$BODY" \
        && fail "${entry} 里出现了 ${forbidden}：拖框中禁止写 project"
    done
  fi
done
# 落地只有一次，且只在松手那一下。
if BODY="$(require_func 'private func endMarquee' "$MARQUEE_VIEW")"; then
  COUNT="$(printf '%s\n' "$BODY" | grep -c 'applyBoxSelection' || true)"
  [ "$COUNT" -eq 1 ] || fail "endMarquee 里有 ${COUNT} 处 applyBoxSelection，应当正好 1 处"
fi
# 拖框中的高亮必须走「看框不看模型」的那个助手，绕过去就没有实时反馈了。
grep -q 'isSelected: isSelected(clip: clip.id)' "$VIEW" \
  || fail "剪辑块的选中态没走 isSelected(clip:)：拖框中不会实时高亮"
grep -q 'isSelected: isSelected(shape: shape.id)' "$SHAPE_ROW" \
  || fail "形状块的选中态没走 isSelected(shape:)：拖框中不会实时高亮"
grep -q 'isSelected: isSelected(text: overlay.id)' "$TEXT_ROW" \
  || fail "文字块的选中态没走 isSelected(text:)：拖框中不会实时高亮"
grep -q 'isSelected(cue: cue.id)' "$SUBTITLE_ROW" \
  || fail "字幕 cue 的选中态没走 isSelected(cue:)：拖框中不会实时高亮"
# 混选只能从 selectBox 这一个入口进来。
OTHER_BOX="$(grep -rn 'selectBox(' Sources/SrtFlow --include='*.swift' \
  | grep -v 'VideoEditSelection.swift' \
  | grep -v 'VideoEditProject.swift:.*selection.selectBox' || true)"
[ -z "$OTHER_BOX" ] || fail "selectBox 只能由 EditSelection 自己实现、由 applyBoxSelection 转发：$OTHER_BOX"

# ── 5. 移动手势必须钉在不会动的参照系上 ────────────────────────────────
# 块自己会在手指底下挪窝（.offset），边缘自动滚动还会把整块内容抽走，
# 两者都会污染以块自身为参照的 translation。
# 光查「有没有写 coordinateSpace:」是假绿 —— 写成 .local 一样能绿。
GESTURE="$(grep -n 'DragGesture(minimumDistance: 4' "${TIMELINE_VIEWS[@]}" || true)"
if [ -z "$GESTURE" ]; then
  fail "找不到块的移动手势，接线守卫失去目标"
else
  while IFS= read -r line; do
    grep -q 'coordinateSpace: \.named(VideoEditTimelineView\.scrollSpace)' <<<"$line" \
      || fail "移动手势没钉在滚动视口坐标系上：$line"
  done <<< "$GESTURE"
fi
# 三类块都要真的把移动手势接上：剪辑、形状、字幕 cue。少一类，「拖任意一个被
# 选中的东西，整片跟着走」对那一类就是空话 —— cue 就这么漏过一轮（复审第 3 条）。
# 不用「数手势个数」：容器上还挂着拉框手势，数得出来的绿是假绿。
if BODY="$(require_func 'func subtitleRow' "$SUBTITLE_ROW")"; then
  grep -q 'DragGesture(minimumDistance: 4' <<<"$BODY" \
    || fail "字幕 cue 块没有移动手势：从 cue 起手拖不动整组"
  grep -q 'beginCueDrag(' <<<"$BODY" \
    || fail "字幕 cue 的手势没冻结这一轮的输入（beginCueDrag）"
  grep -q 'endClipDrag(' <<<"$BODY" \
    || fail "字幕 cue 的手势没有落地入口（endClipDrag）"
  # 隐藏 = 不可编辑（与 trackRow 同一条合同）。只灰显不挡事件的话，隐藏的字幕行
  # 照样拖得动，而且改的是**两条**镜像轨的时间。
  grep -q 'allowsHitTesting(!hidden)' <<<"$BODY" \
    || fail "字幕行隐藏后仍然吃事件：隐藏轨必须不可编辑"
  # 起手判据要带上「有没有活着的会话」，否则被打断后留下的陈旧 id 会让同一条 cue
  # 的下一次拖动整轮建不出会话。
  grep -q 'clipDrag == nil || movingCueID != cue.id' <<<"$BODY" \
    || fail "cue 起手只比了 id：手势被打断后同一条 cue 会失效一次"
fi
# 视图消失时，手势的所有残留状态都要清干净（会话 + 起手标记）。
if BODY="$(extract_func '.onDisappear {' "$VIEW")"; then
  grep -q 'movingCueID = nil' <<<"$BODY" \
    || fail "onDisappear 没清 movingCueID：下一次拖同一条 cue 会失效一次"
fi
grep -q 'onDragBegin: { beginShapeDrag(shape) }' "$SHAPE_ROW" \
  || fail "形状块没有接上 beginShapeDrag"
grep -q 'beginClipDrag(' "$VIEW" || fail "剪辑块没有接上 beginClipDrag"

# ── 5b. 框选的纵向命中必须按「画出来的块」算，不是整行 ─────────────────
# 字幕/形状块在行内上下都留了白，按整行判的话框从留白里扫过也会选中。
if BODY="$(require_func 'private func marqueeRows' "$MARQUEE_VIEW")"; then
  for constant in 'shapeTopInset' 'shapeHeight' 'cueTopInset' 'cueHeight'; do
    grep -q "TimelineMarquee.${constant}" <<<"$BODY" \
      || fail "marqueeRows 没用 TimelineMarquee.${constant}：框选纵向又按整行判了"
  done
fi
# 画块的地方必须读同一批常量，否则「画」和「判」还是会分叉。
for constant in 'shapeTopInset' 'shapeHeight' 'cueTopInset' 'cueHeight'; do
  COUNT="$(grep -h -c "TimelineMarquee.${constant}" "${TIMELINE_VIEWS[@]}" | paste -sd+ - | bc)"
  [ "$COUNT" -ge 2 ] || fail "TimelineMarquee.${constant} 在视图里只用了 ${COUNT} 处：画和判没共用"
done

# ── 6. 缩放只有一个会夹范围的入口 ──────────────────────────────────────
# pps 掉到 1 以下时，位移换算会被 max(pps, 1) 兜底，1:1 跟手当场坏掉。
grep -n 'pixelsPerSecond.wrappedValue = ' "$ZOOM" | grep -vc 'clamped' >/dev/null \
  && fail "捏合直接给 pixelsPerSecond 赋了未夹的值"
grep -rn 'project.pixelsPerSecond = \|pixelsPerSecond = min(\|pixelsPerSecond = max(' Sources/SrtFlow/VideoEditView.swift \
  && fail "工具栏绕开了 setPixelsPerSecond 这个唯一缩放入口"

# ── 7. 自动滚动的心跳必须有取消兜底 ────────────────────────────────────
grep -q 'deinit' "$DRAG" || fail "TimelineAutoScroller 没有 deinit 兜底，timer 可能永远留在 RunLoop 上"
grep -q 'dismantleNSView' "$GEOMETRY" || fail "滚动视图参照物没有 dismantleNSView：视图树拆掉后心跳还在跑"
grep -q 'onDisappear' "$VIEW" || fail "时间线没有 onDisappear：视图消失时自动滚动不会停"

# ── 8. 块内装饰内容不吃事件 ────────────────────────────────────────────
# `.clipped()` / `.clipShape` 只裁绘制，**不裁命中区**。缩略图 `.scaledToFill()`
# 后被裁掉的溢出照样参与命中：竖版图在宽 tile 下（tile 宽随缩放涨）隐形命中区
# 能高出块几百 pt，把标尺整段盖死 —— 点标尺变成选中图片
# （docs/bugfixes/2026-08-16-clipped-thumbnail-hit-area-covers-ruler.md）。
# 装饰(缩略图条/波形/关键帧菱形)必须整条 allowsHitTesting(false)；
# 交互统一由 ClipBlockView 那层的手势 + 底色矩形命中面承担。
extract_struct() {
  awk -v pat="$1" '
    index($0, pat) { inside = 1 }
    inside { print }
    inside && /^\}$/ { exit }
  ' "$2"
}
for deco in "struct ThumbnailStripView:${THUMBS}" "struct WaveformView:${WAVEFORM}"; do
  DECO_FILE="${deco##*:}"
  DECO_NAME="${deco%:*}"
  BODY="$(extract_struct "$DECO_NAME" "$DECO_FILE")"
  if [ -z "$BODY" ]; then
    fail "找不到 ${DECO_NAME}（在 ${DECO_FILE}），装饰命中守卫失去目标 —— 改名了就同步改这里"
  else
    grep -q 'allowsHitTesting(false)' <<<"$BODY" \
      || fail "${DECO_NAME} 没有 allowsHitTesting(false)：scaledToFill 的隐形溢出会把标尺/空白变成块的命中区"
  fi
done
if BODY="$(extract_func 'private var keyframeMarkers' "$CLIP_BLOCK")"; then
  grep -q 'allowsHitTesting(false)' <<<"$BODY" \
    || fail "keyframeMarkers 没有 allowsHitTesting(false)：菱形会抢走块的点击"
fi

# ── 9. 滚动量只有一个来源：从 NSScrollView 现读 ────────────────────────
# 框选是时间线上唯一用**绝对坐标**的手势：手势报的是指针在视口里的位置，框要画
# 在滚动内容里，中间差的正是这一份滚动量。它以前由「GeometryReader → preference
# → @State」异步喂过来，起手那一拍读到的可能还是上一次布局的值，框就整体画到
# 指针左边、偏差正好等于当时的滚动量，滚得远一点框直接跑出视口 = 看起来「框选
# 没反应」（docs/bugfixes/2026-09-18-marquee-anchored-at-stale-scroll-offset.md）。
# 别的手势走 translation 这种相对量，同一个错误在它们身上自己抵消 —— 所以这条
# 只能靠守卫钉住，出了事也只有框选看得见。
[ -f "$GEOMETRY" ] || fail "找不到 ${GEOMETRY}：滚动量的现读入口没了"
# 9a. 谁都不许再把滚动量缓存进视图状态，或退回 preference 那条异步链路。
for file in "${TIMELINE_VIEWS[@]}"; do
  [ -f "${file}" ] || continue
  grep -n '@State.*scrollOffset' "${file}" \
    && fail "${file} 又把滚动量缓存进了 @State：手势要的是现读值"
done
grep -rn 'TimelineScrollOffsetKey\|preference(\s*key: *TimelineScroll' Sources/SrtFlow --include='*.swift' \
  && fail "滚动量又走回 preference 观察：那是异步的，起手那一拍会读到旧值"
# 9b. 框选的锚点和当前点都必须现读（两处都要，只改一处 = 框会自己长歪）。
for entry in 'private func beginMarquee' 'private func applyMarqueePoint'; do
  if BODY="$(require_func "$entry" "$MARQUEE_VIEW")"; then
    grep -q 'scrollGeometry\.offsetX' <<<"$BODY" \
      || fail "${entry} 没有现读滚动量（scrollGeometry.offsetX）：框会偏出一个滚动量"
  fi
done
# 9c. 五个拖动入口冻结的「起手滚动量」同样现读 —— 那个值和自动滚动中的现读值
# 相减，差一点点就是块在自动滚动开始那一瞬间猛跳一段。
COUNT="$(grep -c 'originScrollOffset: scrollGeometry\.offsetX' "$DRAG_WIRING" || true)"
[ "$COUNT" -eq 5 ] \
  || fail "拖动入口只有 ${COUNT} 处现读起手滚动量，应当 5 处（剪辑/形状/文字/字幕/滤镜）"
# 9d. 除了几何入口，谁都不许自己去摸滚动位置。捏合那条是按坐标 hitTest 现找的
# 独立路径（事件监视器里拿不到视图树），暂时豁免。
OTHER_SCROLLER="$(grep -rn 'contentView\.bounds\.origin\|clipView\.scroll(to:' Sources/SrtFlow --include='*.swift' \
  | grep -v "^${GEOMETRY}:" | grep -v "^${ZOOM}:" || true)"
[ -z "$OTHER_SCROLLER" ] \
  || fail "滚动位置只能由 TimelineScrollGeometry 读/推：${OTHER_SCROLLER}"

# ── 10. 纵向滚动：两处「钉住」必须同源，且只有它们订阅滚动量 ───────────
# 轨道多到一屏放不下时时间线双向滚动（2026-09-18）。轨道头列在滚动区外、标尺在
# 滚动内容里，两边各自减/加**同一个** `geometry.offset.y` 才能永远对得上。
# 案例：docs/bugfixes/2026-09-18-timeline-cannot-scroll-vertically.md
grep -q 'ScrollView(\[\.horizontal, \.vertical\]' "$VIEW" \
  || fail "时间线不是双向滚动了：轨道一多下面几条又会被整条裁掉"
grep_code 'offset(y: -geometry\.offset\.y)' "$HEADER_COLUMN" \
  || fail "轨道头列没跟着纵向滚动量走：它和轨道行会错开"
grep_code 'offset(y: geometry\.offset\.y)' "$RULER" \
  || fail "标尺没钉住：纵向滚动时刻度会跟着轨道一起滚走"
# 轨道头列的固有高度是所有行加起来（十来条轨 500pt 往上）。直接摆进 HStack 的话
# 整条时间线会按这个高度要地方，VSplitView 给不了，工具栏和标尺当场被挤出窗口。
if BODY="$(require_func 'var body: some View' "$HEADER_COLUMN")"; then
  grep -q 'Color.clear' <<<"$BODY" \
    || fail "轨道头列又自己决定高度了：它必须画在弹性容器上，否则会把工具栏挤出窗口"
fi
# 订阅（@ObservedObject）只许出现在这两处：别处订阅 = 滚动的每一帧重建整棵
# 时间线视图树（和第 0 节「拖动中不写 state」同一条理由，换了个轴）。
SUBSCRIBERS="$(grep -ln '@ObservedObject var geometry: TimelineScrollGeometry' "${TIMELINE_VIEWS[@]}" || true)"
EXPECTED="$(printf '%s\n%s\n' "$HEADER_COLUMN" "$RULER" | sort)"
[ "$(printf '%s\n' "$SUBSCRIBERS" | sort)" = "$EXPECTED" ] \
  || fail "订阅滚动量的不只是轨道头列和标尺：$SUBSCRIBERS"
grep -q '@State var scrollGeometry = TimelineScrollGeometry()' "$VIEW" \
  || fail "时间线主体必须用 @State 持有滚动几何（@StateObject/@ObservedObject 会订阅 → 每帧重建整棵树）"
# 播放跟随只碰横向：scrollTo 的锚点是双轴的，会把正在看的下面几条轨拽回顶上。
# （注释里提这个名字不算 —— 只看真代码行。）
grep -rn 'scrollTo(' "${TIMELINE_VIEWS[@]}" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' \
  && fail "播放跟随又走回 ScrollViewProxy.scrollTo：那个锚点是双轴的，会把纵向位置一起拽走"
# 没在推的那一轴一个字都不许碰：内容比视口窄时 SwiftUI 会居中（origin 是负的），
# 顺手夹一下就会让整条时间线横着跳一大段。
if BODY="$(require_func 'private func scroll(dx' "$GEOMETRY")"; then
  grep -q 'dx == 0 ? current.x' <<<"$BODY" \
    || fail "scroll(dx:dy:) 把没在推的那一轴也夹了：纵向自动滚动那一拍会横着跳"
  grep -q 'dy == 0 ? current.y' <<<"$BODY" \
    || fail "scroll(dx:dy:) 把没在推的那一轴也夹了：横向自动滚动那一拍会竖着跳"
fi
# 框选的两个端点在**两个轴**上都要补滚动量。
for entry in 'private func beginMarquee' 'private func applyMarqueePoint'; do
  if BODY="$(require_func "$entry" "$MARQUEE_VIEW")"; then
    grep -q 'scrollGeometry\.offsetY' <<<"$BODY" \
      || fail "${entry} 没补纵向滚动量：滚下去之后框会整体偏出一个纵向滚动量"
  fi
done
# 跨轨判定要按「此刻露出来的是哪几条轨」算（纵向自动滚动期间指针不动、内容在滚）。
if BODY="$(require_func 'func verticalTarget(' "$DRAG_WIRING")"; then
  grep -q 'originScrollOffsetY' <<<"$BODY" \
    || fail "verticalTarget 没补纵向滚动量：纵向自动滚出来的轨道永远选不中"
fi

# ── 11. 三个开关的默认值（产品口径，2026-09-18 用户拍板）──────────────
# 默认**只开吸附**：磁吸会自动合拢主轨空档，而这个用户就是要留着间隙剪；链接会
# 把分离出来的音频一起拖走。三个都不持久化，所以这里的字面量就是每次启动的状态
# —— 顺手「改回 true」会静默改掉整个剪辑手感。
grep_code '@Published var magnetEnabled = false' "$PROJECT" \
  || fail "磁吸的默认值不是关：用户的剪法要留间隙，默认合拢会把间隙吃掉"
grep_code '@Published var snappingEnabled = true' "$PROJECT" \
  || fail "吸附的默认值不是开：三个开关里只有它该默认开着"
grep_code '@Published var linkageEnabled = false' "$PROJECT" \
  || fail "链接的默认值不是关：默认会把分离出来的音频一起拖走"

# ── 12. 播放头的把手跟标尺一起钉住 ─────────────────────────────────────
# 标尺是不透明的（要盖住滚上来的轨道行）。把手画在滚动内容顶部的话，纵向滚下去
# 之后它就藏到标尺后面了 —— 竖线还在，抓手没了。
grep_code 'offset(x: playheadX' "$RULER" \
  || fail "标尺没画播放头把手：纵向滚下去之后把手会被标尺盖住"
if BODY="$(require_func 'private var playhead' "$VIEW")"; then
  grep -q 'frame(width: 9, height: 14)' <<<"$BODY" \
    && fail "播放头把手又画回滚动内容里了：纵向滚下去会被钉住的标尺盖住"
fi

# ── 13. 轨道头：三格固定宽度 + 点一下选中整行 ──────────────────────────
# 路径先确认：扫空文件还是绿的（第 0 节同一条教训）。
for file in "$ROW_SELECT_ENTRY" "$ROW_SELECT_RULE"; do
  [ -f "${file}" ] \
    || fail "找不到 ${file}：轨道头点选的判据/接线被改名了，守卫会扫空 —— 同步改这里"
done
# 「隐藏的行点不出选择」这条必须留在纯值里（自检编得动它），别挪回视图。
grep_code 'isLaneHidden' "$ROW_SELECT_RULE" \
  || fail "轨道头点选不再判隐藏轨了：会选中一批在时间线上碰都碰不到的块，⌫ 一按就删"
# 对齐：色条/图标/眼睛三格**都得写死宽度**。靠 HStack 居中的话，film 比
# music.note 宽、字幕行没有色条，每行总宽不同 → 色条和眼睛的 x 一行一个样
#（2026-09-18 用户报的「这一列要对齐」）。
for cell in 'TimelineHeaderMetrics.accentWidth' 'TimelineHeaderMetrics.iconWidth' \
            'TimelineHeaderMetrics.faderWidth' 'TimelineHeaderMetrics.eyeWidth'; do
  grep_code "frame(width: ${cell})" "$HEADER_COLUMN" \
    || fail "轨道头少了固定宽度的那一格（${cell}）：这一列又会一行一个样"
done
# 推子（2026-09-23）：没有推子的行也占着那一格；拖动中不写 state（同音量线）；
# 标尺那一行放总推子（docs/architecture/audio-mixer.md）。
if BODY="$(require_func 'private var fader: some View' "$HEADER_COLUMN")"; then
  grep -q 'Color.clear' <<<"$BODY" \
    || fail "没有推子的行没占住推子那一格：它的眼睛会跑到别人推子的位置上"
  grep -q 'onLive: { project.previewTrackVolume' <<<"$BODY" \
    || fail "拖轨道推子时没走 previewTrackVolume：要么听不见，要么每一拍写 state"
fi
grep_code 'masterStrip' "$HEADER_COLUMN" || fail "标尺那一行的总推子不见了"
# 电平表：轨道推子读自己那条轨、总推子读总表（docs/architecture/audio-mixer.md）。
grep_code 'key: .track(' "$HEADER_COLUMN" || fail "轨道推子没接上自己那条轨的电平表"
grep_code 'key: .master' "$HEADER_COLUMN" || fail "总推子没接上总电平表"
# tap 必须跟着合成活：预览重建时整批重来，其余换 mix 的地方都挂回同一批（新建会卡 0.6 秒）。
grep_code 'meters.beginComposition()' "$PROJECT" \
  || fail "预览重建时没让电平表的 tap 整批重来：旧 tap 挂在旧 item 上"
[ "$(grep -c 'meters: meters' "$PROJECT")" -ge 3 ] \
  || fail "有换 audioMix 的地方没挂回电平表的 tap（重建 / 快路径 / 试听三处都要）"
if grep -vE '^[[:space:]]*//' Sources/SrtFlow/VideoEditTrackFader.swift | grep -cE 'project\.|perform|liveApply' >/dev/null; then
  fail "推子视图自己去碰 project 了：它只该回调 onLive / onCommit（拖动中不写 state）"
fi
# 没有色条/没有眼睛的行也必须占着那一格，否则那几行整体左移。
if BODY="$(require_func 'private var eye: some View' "$HEADER_COLUMN")"; then
  grep -q 'Color.clear' <<<"$BODY" \
    || fail "没有眼睛的行没占住眼睛那一格：它的图标会跑到别人眼睛的位置上"
fi
# 点选：轨道头点一下选中整行，判据只有 TimelineRowSelection 一份。
grep_code 'project.selectRow(' "$HEADER_COLUMN" \
  || fail "轨道头没接上点选：点非眼睛的地方应当选中这一行的全部素材"
grep_code 'selectedClipIDs\|selectedShapeIDs\|selectedTextIDs\|selectedSubtitleCueIDs' "$HEADER_COLUMN" \
  && fail "轨道头自己写选择了：只能走 project.selectRow（判据留在 TimelineRowSelection）"
if BODY="$(require_func 'func selectRow(' "$ROW_SELECT_ENTRY")"; then
  grep -q 'TimelineRowSelection.ids(' <<<"$BODY" \
    || fail "selectRow 没走纯值 TimelineRowSelection.ids：那份判据自检就够不着了"
  grep -q 'guard !result.isEmpty else { return }' <<<"$BODY" \
    || fail "selectRow 少了空行早退：点空轨会把用户已有的选择抹掉"
fi
# 眼睛必须还是 Button：它自己把点击吃掉，才不会连带触发整行点选。
if BODY="$(require_func 'private func eyeButton(' "$HEADER_COLUMN")"; then
  grep -q 'Button(action: action)' <<<"$BODY" \
    || fail "眼睛不是 Button 了：点眼睛会连带把整条轨的素材选中"
fi

# ── 13b. 行高：一轨一个值，且不许进撤销栈 ──────────────────────────────
# 2026-09-22 之前行高是「一类一个值」，拖一条音频轨，所有音频轨一起变高。
# 夹紧和存储的规则是纯值（scripts/check-project-file.sh 钉），这里钉接线：
# 键必须是轨道身份、起手值必须认轨、写入不许走 TimelineState。
grep_code 'let key: TimelineRowHeightKey?' "$ROW_HEIGHT_DRAG" \
  || fail "行高拖动不是按轨道身份接的：又回到「拖一条、同类一起动」"
grep_code 'var key: TimelineRowHeightKey' "$ROW_HEIGHT_DRAG" \
  || fail "行高拖动的起手值没带「是哪条轨」：onEnded 不保证会来，残留值会让下一条轨从别人的高度起算"
if BODY="$(require_func 'private func base(for key' "$ROW_HEIGHT_DRAG")"; then
  grep -q 'session.key == key' <<<"$BODY" \
    || fail "行高拖动的起手值没认轨：拖完 A 再拖 B，B 会从 A 的高度跳一下"
fi
# 行高只从 project.rowHeight( 取一份。视图里直接读「一类一个值」的默认高度，
# 就等于把那条老毛病又接回来了。
for forbidden in 'project.defaultVideoRowHeight' 'project.defaultAudioRowHeight'; do
  grep_code "$forbidden" "$VIEW" \
    && fail "时间线的行高又直接读这一类的默认值（${forbidden}）：同类的轨会一起动"
done
grep_code 'project.rowHeight(' "$VIEW" \
  || fail "时间线的行高不再走 project.rowHeight：一轨一个值的那份账就没人认了"
grep_code 'key: row.heightKey' "$HEADER_COLUMN" \
  || fail "轨道头没把这一行的行高键传给拖动：又会按类去调"
# 写入不许碰 TimelineState：进了撤销栈，调完行高按 ⌘Z 撤掉的是行高而不是
# 用户上一次真编辑；走 perform 还会顺手重建预览，拖一下画面闪一次。
if BODY="$(require_func 'func setRowHeight(' "$PROJECT")"; then
  for forbidden in 'perform' 'liveApply' 'state =' 'scheduleRebuild'; do
    grep -q "$forbidden" <<<"$BODY" \
      && fail "setRowHeight 里出现了 ${forbidden}：行高是装饰状态，不许进撤销栈/重建预览"
  done
  grep -q 'documentDidChange()' <<<"$BODY" \
    || fail "setRowHeight 没标脏：调好的行高不会被自动保存带进工程文件"
fi

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


# ── 滚动内容必须填满视口、左上角对齐（两轴都要） ──────────────────────
# 内容比视口小时 SwiftUI 的 ScrollView 会把它**居中**，两根轴各自连出 bug：
#
# 纵向（轨道少，常态；2026-09-20 用户报的）：
#   1. 播放头那条线只画在居中后那一段，上面接不到标尺 —— 「指针是断的」；
#   2. 标尺靠 `.offset(y: geometry.offset.y)` 被拉回视口顶上，但它的**命中区
#      没跟过去**，点可见的标尺 seek 不了 —— 「播放头没法移动」。
# 横向（工程短 + 窗口宽，同样是常态；2026-09-21 用户报的）：
#   3. 整条时间线飘到视口中间 —— 「刚加进来的素材没贴左边」；
#   4. 框选算的是 `内容 x = 视口 x + offsetX`（见上面 §5b 那组守卫），居中
#      把这个前提打破了，框整体偏到指针右边 (视口宽 - 内容宽)/2。
# 四个症状同一个根。修法就是这一行两轴的 min 尺寸。
if BODY="$(require_func 'private var scrolledContent: some View' "$VIEW")"; then
  # 三个条件写在**同一行**上匹配：分开写的话 `alignment: .topLeading` 会被上一
  # 行 `.frame(width: contentWidth, alignment: .topLeading)` 顺手匹配掉，对齐
  # 那条就成了永远为真的假绿；只查 minHeight 的话横向那一半照样能溜过去。
  printf '%s\n' "$BODY" \
    | grep -c 'minWidth: viewportWidth, minHeight: viewportHeight, alignment: \.topLeading)' >/dev/null \
    || fail "时间线滚动内容没有 .frame(minWidth: viewportWidth, minHeight: viewportHeight, alignment: .topLeading)：内容比视口小时会被居中 —— 纵向会让播放头断线、标尺点不动，横向会让素材不贴左边、框选整体偏到指针右边"

  # 2026-09-21 第二轮补的那条：**撑出来的空白必须在命中区里面**。
  # `.contentShape` 摆在那个 frame 前面的话（改成「点空白移播放头」之前就是这样），
  # 能点的只有 contentWidth 那一段 —— 工程短时它是 600pt 的地板，窗口一宽，右边
  # 小半个视口是彻底的死区：点了不移播放头、不清选择，框也拉不起来。
  # 所以除了「那一行在」，还得钉**顺序**：按行号比大小，比对最后一个 contentShape
  #（前面还有一个，是内容区那一层自己的，只盖到 contentWidth 为止）。
  line_of() { printf '%s\n' "$BODY" | grep -nE "$1" | eval "$2" | cut -d: -f1; }
  FILL_LINE="$(line_of '^[[:space:]]*\.frame\(minWidth: viewportWidth' 'head -1')"
  SHAPE_LINE="$(line_of '^[[:space:]]*\.contentShape\(Rectangle\(\)\)' 'tail -1')"
  TAP_LINE="$(line_of '^[[:space:]]*\.onTapGesture' 'tail -1')"
  MARQUEE_LINE="$(line_of '^[[:space:]]*\.gesture\(marqueeGesture' 'tail -1')"
  for probe in "$FILL_LINE" "$SHAPE_LINE" "$TAP_LINE" "$MARQUEE_LINE"; do
    [ -n "$probe" ] || fail "scrolledContent 的修饰符栈里少了填满视口的 frame / contentShape / 点击 / 框选中的某一个，顺序守卫失去目标"
  done
  if [ -n "$FILL_LINE" ] && [ -n "$SHAPE_LINE" ] && [ -n "$TAP_LINE" ] && [ -n "$MARQUEE_LINE" ]; then
    [ "$FILL_LINE" -lt "$SHAPE_LINE" ] \
      || fail "命中区（.contentShape）排在「填满视口」的 frame 前面：右边撑出来的那片空白会变成死区，点不动播放头也拉不起框"
    [ "$SHAPE_LINE" -lt "$TAP_LINE" ] && [ "$SHAPE_LINE" -lt "$MARQUEE_LINE" ] \
      || fail "点击 / 框选没挂在最后那个 .contentShape 之后：它们吃到的还是内容区那一层的命中形状"
    # **拖放落点同样要盖住撑出来的空白**（2026-09-23）：整条时间线只有一个落点
    #（`TimelineDropRouter`，理由见下面「从 Finder 拖文件进轨道」那一节第 1 条），
    # 右边 / 下边撑出来的空白也要接得住从 Finder 拖进来的文件。挂在那个 frame
    # 前面的话它只盖到内容区为止，空白处的拖入就落到整页那条兜底上（接主轨末尾），
    # 「拖到哪落到哪」在空白处不成立。
    ROUTER_LINE="$(line_of '^[[:space:]]*\.onDrop\(of: TimelineDropRouter\.types, delegate: timelineDropRouter\)' 'head -1')"
    if [ -z "$ROUTER_LINE" ]; then
      fail "scrolledContent 上没挂 .onDrop(of: TimelineDropRouter.types, delegate: timelineDropRouter)：文件和三套卡片拖放全都没有落点"
    else
      [ "$SHAPE_LINE" -lt "$ROUTER_LINE" ] \
        || fail "拖放落点排在最后那个 .contentShape 前面：视口撑出来的空白接不住拖入"
    fi
  fi
fi

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

# ── 从转场库拖卡片到接缝 ──────────────────────────────────────────────
# 时间线在这之前**零 SwiftUI 拖放**（块的移动/裁切、标尺 scrub 全是 DragGesture），
# 这是新起的一套。落点算法与落点框的几何由 checks/TimelineSnap §28-§30 守着 ——
# 那些断言全过、接线接错的话，用户拖上去照样什么都不会发生。
DRAG="Sources/SrtFlow/VideoEditTransitionDrag.swift"
PICKER="Sources/SrtFlow/VideoEditTransitionPicker.swift"
for f in "$DRAG" "$PICKER"; do
  [ -f "$f" ] || fail "文件不在：$f"
done

# 注释行不算数：说明里写「不能用 .fileURL」是交代，不是违规。
drag_hits() { grep -vE '^[[:space:]]*(//|\*)' "$1" | grep -cE "$2" || true; }

# 1) 拖源：卡片要能拖，且用的就是那个自定义类型。
[ "$(drag_hits "$PICKER" '\.onDrag \{ TransitionDrag\.itemProvider\(for: kind\) \}')" -ne 0 ] \
  || fail "转场卡片没挂 .onDrag：库里的卡片拖不动"

# 2) 落点：时间线上唯一的路由器按**主轨那一行**的纵向范围分派转场（2026-09-23 之前
#    挂在每条轨道行上、非主轨传空类型 —— 空类型的落点照样独占拖入，滤镜 / 音频库
#    卡片和 Finder 的文件拖到轨道行上全被它吞掉，见 timeline-drag-gestures.md §5e-2）。
#    藏起来的主轨不接转场：mainRow 只取**没藏**的主轨行。
[ "$(drag_hits "$VIEW" 'spec\.slot == \.main && !\$0\.spec\.isHidden')" -ne 0 ] \
  || fail "路由器的 mainRow 没按「主轨且没藏」取：转场会落到藏起来的主轨上，或者哪儿都落不下"
[ "$(drag_hits "$VIEW" 'transition: TransitionDropDelegate\(')" -ne 0 ] \
  || fail "路由器没接转场代理：拖卡片到接缝上没反应"

# 3) 两处用**同一个**类型常量。各写一个字面量的话，改一处就再也拖不上去，
#    而且两边都「看起来是对的」。
[ "$(drag_hits "$DRAG" 'static let typeIdentifier = "com\.srtflow\.transition"')" -ne 0 ] \
  || fail "$DRAG 里没有那个类型标识符常量"
#    **别整文件豁免**：只把 VideoEditTransitionDrag.swift 排除掉的话，在**那个
#    文件里**再写一处字面量照样绿（初版就是这么假绿的，反向探针当场抓到）。
#    改成数全仓非注释行里的字面量，必须正好一次 —— 就是那条 typeIdentifier。
ID_LITERALS="$(grep -rhE 'com\.srtflow\.transition' Sources/SrtFlow --include='*.swift' \
  | grep -vE '^[[:space:]]*(//|\*)' | wc -l | tr -d ' ')"
[ "$ID_LITERALS" -eq 1 ] \
  || fail "类型标识符的字面量出现了 $ID_LITERALS 次（应为 1）：只许 TransitionDrag.typeIdentifier 那一处，别处一律引用它"

# 4) 载荷**不许**用 .fileURL：VideoEditView 整个挂着 .onDropOfFiles，
#    同一个类型两边都认领会打架。
[ "$(drag_hits "$DRAG" 'UTType\.fileURL|\.fileURL')" -eq 0 ] \
  || fail "转场拖放用了 .fileURL：会和 VideoEditView 的 .onDropOfFiles 抢同一种拖入"

# 5) 落地和画框必须走**同一个**函数、同一个坐标。各算一次的话，框画在这条缝上、
#    转场却落到另一条 —— 最难查的一种错。performDrop 里不许回读那份 @State。
if DROP_BODY="$(awk '/func performDrop\(info: DropInfo\)/,/^    \}/' "$DRAG")"; then
  grep -qE 'let target = target\(info\)' <<<"$DROP_BODY" \
    || fail "performDrop 没有用 target(info) 重算落点：读 @State 会和画框那一拍脱节"
fi

# 6) 落点框只画不吃事件：它盖在主轨上，吃掉 hit test 就会把落点自己挡住
#    （同第 8 节「块内装饰不吃事件」的理由）。
if IND_BODY="$(awk '/struct TransitionDropIndicator/,0' "$DRAG")"; then
  grep -q 'allowsHitTesting(false)' <<<"$IND_BODY" \
    || fail "落点框没有 allowsHitTesting(false)：会挡住自己的落点"
fi

# 7) 拖动**过程**中一个字都不写模型（§0）：代理里只有 performDrop 能落地。
NON_DROP="$(awk '/struct TransitionDropDelegate/,/^\}/' "$DRAG" \
  | awk '/func (validateDrop|dropEntered|dropUpdated|dropExited)/,/^    \}/' \
  | grep -nE 'project\.(perform|liveApply|applyTransition|setTransition)' || true)"
[ -z "$NON_DROP" ] || fail "落点代理在拖动过程中写了模型（只有 performDrop 能落地）：$NON_DROP"

# 9) 拖到视口边缘要把时间线推走，否则屏幕外的接缝永远够不着。心跳和剪辑拖动
#    共用同一台 —— 再起一台就又多一个「什么时候推、推多快」的来源。
[ "$(drag_hits "$DRAG" 'autoScroller\.update\(')" -ne 0 ] \
  || fail "转场落点没接边缘自动滚动：拖不到屏幕外的接缝"

# 10) 心跳不许比这一轮拖放活得久：离开和落地两条路都要 stop()，
#     少一条 RunLoop 上就留着一个 60Hz 的空转 timer。
if EXIT_BODY="$(awk '/func dropExited\(info: DropInfo\)/,/^    \}/' "$DRAG")"; then
  grep -q 'autoScroller.stop()' <<<"$EXIT_BODY" \
    || fail "dropExited 没停心跳：指针离开后时间线会一直自己滚"
fi
if DROP_BODY2="$(awk '/func performDrop\(info: DropInfo\)/,/^    \}/' "$DRAG")"; then
  grep -q 'autoScroller.stop()' <<<"$DROP_BODY2" \
    || fail "performDrop 没停心跳：松手后时间线会一直自己滚"
fi

# 11) **只横着滚**。转场只落在主轨那一行，纵向滚下去反而把主轨滚出视口、落点当场
#     消失。传 height: 0 让心跳的纵向那一半整个跳过。
[ "$(drag_hits "$DRAG" 'viewport: CGSize\(width: viewport\.width, height: 0\)')" -ne 0 ] \
  || fail "转场落点的自动滚动没限定成只横向：纵向滚动会把主轨滚出视口"

# 12) 视口坐标靠**现读**的滚动量换算（§5b 同一条）。缓存一份的话，自动滚动期间
#     指针在视口里的位置会越算越偏，边缘带自己就飘走了。
if SCROLL_BODY="$(awk '/private func autoScroll\(contentX: Double\)/,/^    \}/' "$DRAG")"; then
  [ "$(printf '%s\n' "$SCROLL_BODY" | grep -c 'geometry.offsetX')" -ge 2 ] \
    || fail "autoScroll 没有两处现读 geometry.offsetX（换算视口坐标一处、滚动后重算一处）"
fi

# 8) 点一张卡和拖一张卡必须走同一条落地路径，否则同一个动作两个入口两种结果。
[ "$(drag_hits "Sources/SrtFlow/VideoEditProject+TransitionLibrary.swift" 'func applyTransition\(toSeamAfter outgoingID: UUID')" -ne 0 ] \
  || fail "没有共用的 applyTransition(toSeamAfter:_:)：点卡片和拖卡片会分叉"
[ "$(drag_hits "Sources/SrtFlow/VideoEditProject+TransitionLibrary.swift" 'applyTransition\(toSeamAfter: seam\.outgoing\.id')" -ne 0 ] \
  || fail "applyTransitionFromLibrary 没走共用落地函数"

# ── 扫帧 peek 只有一个所有者（2026-09-21 用户拍板：任何地方都能预览） ──
# 鼠标扫过时间线**任何地方**，画面就去看一眼那一帧。入口只能有**一个**：
# 以前它挂在剪辑块自己身上（于是只有视频块本体能预览，标尺/空白/音频轨都没有），
# 现在挂在容器上。两处都在的话，容器和块两圈 hover 都写 `peekTime`，谁后到谁赢
# —— 那是竞态，不是行为。所以这里按**文件**钉：全 Sources 下只准这一个文件出现
# 扫帧入口和 peek 的写入。
HOVER_FILES="$(grep -rlE '^[[:space:]]*\.onContinuousHover' --include='*.swift' Sources | sort | tr '\n' ' ' | sed 's/ $//')"
[ "$HOVER_FILES" = "$VIEW" ] \
  || fail "扫帧入口 .onContinuousHover 出现在 [${HOVER_FILES}]，应当只有 ${VIEW}：多一处就是两圈 hover 抢着写 peekTime 的竞态"
PEEK_FILES="$(grep -rlE '^[^/]*clock\.peek\(at:' --include='*.swift' Sources | sort | tr '\n' ' ' | sed 's/ $//')"
[ "$PEEK_FILES" = "$VIEW" ] \
  || fail "peek(at:) 的写入出现在 [${PEEK_FILES}]，应当只有 ${VIEW}（endPeek 不受限：收掉已经亮着的影子到处都该能做）"

if BODY="$(require_func 'func hoverPeek(' "$VIEW")"; then
  # 和点击同一份夹紧：影子指针指着哪儿、画面就得是哪儿。不夹的话，鼠标扫进
  # 工程长度之外的那片空白，影子一路往右跑而画面早就停在最后一帧了。
  grep -q 'min(max(0, point.x / pps), project.duration)' <<<"$BODY" \
    || fail "hoverPeek 没把扫帧时刻夹进 [0, duration]：影子指针会和画面各说各话"
  # 播放中 / 拖块 / 拖框 / 裁切都不扫帧。裁切那条只能从 project 上判 ——
  # `isTrimming` 是剪辑块内的 @State，容器看不见。
  for guard_expr in '!clock.isPlaying' 'clipDrag == nil' 'marquee == nil' 'project.liveEditOrigin == nil'; do
    grep -qF "$guard_expr" <<<"$BODY" \
      || fail "hoverPeek 少了 ${guard_expr} 这道 guard：按住在动的时候画面会被扫帧抢走"
  done
  # 时刻没变就不写：peekTime 是 @Published，每写一次连带整条时间线视图树重算，
  # 而现在鼠标扫过时间线**任何地方**都会走到这里（纵向移动、亚像素抖动算出来
  # 都是同一刻）。
  grep -q 'clock.peekTime ?? -1' <<<"$BODY" \
    || fail "hoverPeek 少了「时刻没变就不写」的门槛：鼠标每动一下都会重算整条时间线"
fi
if BODY="$(require_func 'func markerPeek(' "$VIEW")"; then
  grep -q 'markerPeekTime = time' <<<"$BODY" \
    || fail "markerPeek 没记下仲裁位：容器下一拍就会把画面从标记那一帧拽回指针底下"
fi

# ── 从 Finder 拖文件进轨道 / ⌘V 粘贴进轨道 ────────────────────────────
# 落点算法本身由 scripts/check-media-import.sh 守着（纯值，45 条断言）。
# 那些断言全过、这里接线接错的话，用户拖上去照样落在主轨末尾 —— 也就是
# 2026-09-22 之前的老样子，而且从界面上完全看不出区别。
# 产品口径：docs/plans/2026-09-22-media-file-drop.md
FILE_DROP="Sources/SrtFlow/VideoEditMediaFileDrop.swift"
MEDIA_IMPORT="Sources/SrtFlow/VideoEditMediaImport.swift"
EDITOR_VIEW="Sources/SrtFlow/VideoEditView.swift"
APP_ENTRY="Sources/SrtFlow/SrtFlowApp.swift"
for f in "$FILE_DROP" "$MEDIA_IMPORT" "$DROP_ROUTER" "$EDITOR_VIEW" "$APP_ENTRY"; do
  [ -f "$f" ] || fail "文件不在：$f"
done

# 1) **整条时间线只许有一个 `.onDrop`**（2026-09-23，探针实测，§5e-2）。
#    SwiftUI 把一次拖放交给指针底下**最里面**那个落点，类型对不上也不往外找，
#    连 `.onDrop(of: [])` 这种空类型的都照样独占。两个落点一里一外叠着，里面
#    那个就吞掉外面那个的拖入 —— 这条规则前后坑了三回：文件落点挂在外面（从
#    Finder 拖不进来）、垫在里面（ea746c1：滤镜 / 音频库 / 转场卡片全死）、每条
#    轨道行上的空类型转场落点（卡片和文件拖到轨道行上都被吞）。
#    数的是时间线这一族**全部**文件，外加四套拖放各自的文件 —— 块、行拆在别的
#    文件里，挂在那儿一样会吞。
DROP_SITES="$(for f in "${TIMELINE_VIEWS[@]}" "$FILE_DROP" "$DRAG" \
    Sources/SrtFlow/VideoEditFilterDrag.swift Sources/SrtFlow/AudioLibraryDrag.swift; do
  [ -f "$f" ] || continue
  # 没匹配时 grep 退出码是 1：pipefail 下不兜住，整个命令替换会让脚本静默退出。
  { grep -nE '\.(onDrop|dropDestination)\(' "$f" || true; } \
    | grep -vE '^[0-9]+:[[:space:]]*(//|\*)' | sed "s|^|$f:|" || true
done)"
DROP_COUNT="$(printf '%s\n' "$DROP_SITES" | grep -c . || true)"
[ "$DROP_COUNT" -eq 1 ] \
  || fail "时间线里有 ${DROP_COUNT} 处 .onDrop / .dropDestination（应为 1：scrolledContent 上的 TimelineDropRouter）—— 多出来的那个会吞掉别人的拖入：$DROP_SITES"

# 1b) 路由器认齐四种载荷，而且**卡片的自定义载荷先认、文件最后认**：卡片的
#     provider 万一同时也给得出 file URL，排反了就会被当成从 Finder 拖进来的文件。
grep -q 'FilterDrag.type, AudioLibraryDrag.type, TransitionDrag.type, .fileURL' "$DROP_ROUTER" \
  || fail "TimelineDropRouter.types 没列齐四种载荷：没列上的那种拖进时间线连 validateDrop 都不会调"
ROUTE_BODY="$(awk '/private func payload\(_ info: DropInfo\)/,/^    \}/' "$DROP_ROUTER")"
if [ -z "$ROUTE_BODY" ]; then
  fail "找不到 TimelineDropRouter.payload（在 ${DROP_ROUTER}）：分派守卫失去目标"
else
  for t in FilterDrag AudioLibraryDrag TransitionDrag; do
    grep -q "\[$t\.type\]" <<<"$ROUTE_BODY" \
      || fail "路由器不认 ${t}：那一套卡片拖上时间线不会有任何反应"
  done
  FILE_ROUTE="$(printf '%s\n' "$ROUTE_BODY" | grep -n '\[\.fileURL\]' | head -1 | cut -d: -f1)"
  LAST_CARD="$(printf '%s\n' "$ROUTE_BODY" | grep -nE '\[(FilterDrag|AudioLibraryDrag|TransitionDrag)\.type\]' \
    | tail -1 | cut -d: -f1)"
  if [ -z "$FILE_ROUTE" ]; then
    fail "路由器不认 .fileURL：从 Finder 拖文件进时间线会没反应"
  elif [ -n "$LAST_CARD" ] && [ "$FILE_ROUTE" -lt "$LAST_CARD" ]; then
    fail "路由器先认 .fileURL 再认卡片：卡片要是同时给得出 file URL，就会被当成文件拖入"
  fi
fi

# 1c) 滤镜只许落在内容区以内、转场只落主轨那一行。以前靠「落点挂在哪」来保证，
#     现在只剩一个落点，改由路由器按坐标判 —— 漏一条，那一套就会落到不该落的地方。
grep -q 'case .filter where withinContent(info)' "$DROP_ROUTER" \
  || fail "路由器没按内容区宽度拦滤镜：滤镜会落进视口撑出来的空白（时间上远超工程长度，看不见也滚不到）"
grep -q 'case .transition where onMainRow(info)' "$DROP_ROUTER" \
  || fail "路由器没按主轨那一行拦转场：拖到别的行上也会接"

# 1d) **松手之后 SwiftUI 还会补发一拍 dropUpdated**（2026-09-23 日志实测：
#     validate → entered → updated… → PERFORM → updated）。这一拍照常转发的话，
#     落点框按落地之后的状态重算、挂在时间线上不走；松手点在视口边缘时自动滚动的
#     心跳还会被重新拉起来。路由器必须先判这一轮还活着没有，四套一个不漏。
if UPD_BODY="$(awk '/func dropUpdated\(info: DropInfo\)/,/^    \}/' "$DROP_ROUTER")"; then
  grep -q 'isLive(payload)' <<<"$UPD_BODY" \
    || fail "路由器的 dropUpdated 没先判 isLive：松手后补发的那一拍会把落点框画回来、把自动滚动重新拉起来"
fi
LIVE_BODY="$(awk '/private func isLive\(_ payload: Payload\)/,/^    \}/' "$DROP_ROUTER")"
for flag in 'MediaFileDrag.pending' 'FilterDrag.preset' 'AudioLibraryDrag.pending' 'TransitionDrag.kind'; do
  grep -qF "$flag" <<<"$LIVE_BODY" \
    || fail "isLive 没看 ${flag}：那一套松手后补发的一拍照样会转发"
done
# 1e) **「这里不能放」只许回 `.forbidden`，不许回 `.cancel`**（2026-09-23 日志实测）。
#     `.cancel` 是「取消这一轮拖放」：回过一次，SwiftUI 之后再也不调 dropUpdated，
#     松手只给 dropExited。转场卡片就这么死的 —— 拖动从标尺那侧进来，第一拍不在
#     主轨那一行，路由器回了 `.cancel`，指针挪到接缝上也救不回来。整条时间线只有
#     一个落点之后，拖动**总是**先经过不能放的地方，所以这条对四套拖放一视同仁。
for f in "$DROP_ROUTER" "$FILE_DROP" "$DRAG" \
         Sources/SrtFlow/VideoEditFilterDrag.swift Sources/SrtFlow/AudioLibraryDrag.swift; do
  CANCELS="$({ grep -nE 'DropProposal\(operation:[^)]*\.cancel' "$f" || true; } \
    | grep -vE '^[0-9]+:[[:space:]]*//' || true)"
  [ -z "${CANCELS}" ] \
    || fail "${f} 的落点回了 .cancel：那会取消整轮拖放，之后不再有 dropUpdated，挪到能放的地方也救不回来 —— 改成 .forbidden：${CANCELS}"
done

#     文件那一套还要自己守住：暂存清空之后 plan 返回 nil，不许「补探一次」——
#     初版这么写过，补发的那一拍就把框按落地之后的状态画了回来（实测）。
grep -q 'guard let pending = MediaFileDrag.pending, !pending.isUnusable else { return nil }' "$FILE_DROP" \
  || fail "文件落点的 plan 在没有暂存时没返回 nil：这一轮收尾之后还会画框"
if TRACK_BODY="$(awk '/private func track\(_ location: CGPoint\)/,/^    \}/' "$FILE_DROP")"; then
  grep -vE '^[[:space:]]*//' <<<"$TRACK_BODY" | grep -c 'beginProbe' >/dev/null \
    && fail "文件落点的 track 里在补探：松手后补发的那一拍会把落点框按落地之后的状态重新画出来"
fi

# 2) 兜底那条**必须留着**：拖到预览区 / 检查器 / 库栏上仍要能导入。
[ "$(drag_hits "$EDITOR_VIEW" '\.onDropOfFiles \{ urls in project\.addMedia')" -ne 0 ] \
  || fail "VideoEditView 的 .onDropOfFiles 兜底没了：拖到预览区 / 检查器 / 库栏上会彻底没反应"

# 3) 另外三套应用内拖放**一律不许**用 .fileURL。它们要是也认 file-url，
#    一次文件拖入就有四个候选接收者，谁接到全看视图树顺序。
for f in Sources/SrtFlow/VideoEditTransitionDrag.swift \
         Sources/SrtFlow/VideoEditFilterDrag.swift \
         Sources/SrtFlow/AudioLibraryDrag.swift; do
  [ "$(drag_hits "$f" 'UTType\.fileURL|\.fileURL')" -eq 0 ] \
    || fail "$f 用了 .fileURL：会和时间线的文件落点、以及 .onDropOfFiles 抢同一种拖入"
done

# 4) **画落点框和真落地共用同一个落点函数。** 各算一遍必然分叉 ——
#    框画在这条轨、素材落到另一条，是这个仓库反复踩的那一类错。
#    全仓恰好两处调用：plan(at:) 画框那一处，importFiles 落地那一处。
LANDING_CALLS="$(grep -rhE 'mediaImportLandings\(' Sources/SrtFlow --include='*.swift' \
  | grep -vE '^[[:space:]]*(//|\*)' | grep -v 'func mediaImportLandings' | wc -l | tr -d ' ')"
[ "$LANDING_CALLS" -eq 2 ] \
  || fail "mediaImportLandings 被调了 ${LANDING_CALLS} 次（应为 2：画框一处、落地一处）—— 多出来的那处就是第二份账"
# 起点也只有一份账（指针对中点 / ⌘V 对播放头都在 importFirstStart 里收口）。
START_CALLS="$(grep -rhE 'importFirstStart\(' Sources/SrtFlow --include='*.swift' \
  | grep -vE '^[[:space:]]*(//|\*)' | grep -v 'func importFirstStart' | wc -l | tr -d ' ')"
[ "$START_CALLS" -eq 2 ] \
  || fail "importFirstStart 被调了 ${START_CALLS} 次（应为 2：画框一处、落地一处）"

# 4b) 磁吸开着时，落点框画在拼完之后的位置：落地走 perform，perform 收尾会 packMain，
#     落主轨的段被拼到故事线末尾。框照指针处画的话就是「框在这儿、素材落到那儿」。
#     挪动本身在纯值的 landingsAfterMagnet 里（scripts/check-media-import.sh 对账）。
if PLAN_BODY="$(awk '/private func plan\(at location: CGPoint\) -> MediaFileDropPlan\?/,/^    \}/' "$FILE_DROP")"; then
  grep -q 'landingsAfterMagnet' <<<"$PLAN_BODY" \
    || fail "文件落点的 plan 没按磁吸拼完之后的位置画框：磁吸开着时框在指针底下、素材却落到主轨末尾"
fi

# 4c) 素材类拖放（Finder 文件、音频库）**左边缘对齐指针**（2026-09-23 用户拍板）。
#     素材往往很长，中点对齐时起点要退回半段时长：60 秒的视频拖到主轨末尾后面，
#     起点退到末尾之前、撞上已有素材被抬轨，要落进主轨得把指针拖到末尾右边 30 秒
#     开外。滤镜卡片时长短，仍按中点，不在这条里。
if START_BODY="$(require_func 'func importFirstStart(anchor:' "$FILE_DROP")"; then
  grep -q '/ 2' <<<"$START_BODY" \
    && fail "importFirstStart 又按中点对齐了：长素材的起点会退回半段时长，拖到主轨末尾后面也落不进主轨"
fi
if AUDIO_PLAN="$(require_func 'private func plan(at location: CGPoint) -> AudioLibraryDropPlan?' Sources/SrtFlow/AudioLibraryDrag.swift)"; then
  grep -q 'duration / 2' <<<"$AUDIO_PLAN" \
    && fail "音频库落点又按中点对齐了：整首音乐的起点会退回一分多钟，拖到哪都落不到指针那儿"
fi

# 5) 落地不许回读那份 @State：@Binding 的写入不是同步可见的，回读会让落点晚
#    一帧（同转场第 5 条）。落点只许从**这一拍的** info.location 算。
if DROP_BODY="$(awk '/func performDrop\(info: DropInfo\)/,/^    \}/' "$FILE_DROP")"; then
  grep -q 'info.location.x / pps' <<<"$DROP_BODY" \
    || fail "文件落点的 performDrop 没按这一拍的指针算时间：读 preview 会和画框那一拍脱节"
  grep -q 'trackTarget(at: info.location)' <<<"$DROP_BODY" \
    || fail "文件落点的 performDrop 没按这一拍的指针算目标轨"
  grep -q 'defer { finish() }' <<<"$DROP_BODY" \
    || fail "文件落点的 performDrop 没收尾（finish）：暂存留着，心跳也可能空转"
fi
if EXIT_BODY="$(awk '/func dropExited\(info: DropInfo\)/,/^    \}/' "$FILE_DROP")"; then
  grep -q 'finish()' <<<"$EXIT_BODY" \
    || fail "文件落点的 dropExited 没收尾（finish）：指针离开后框还挂着"
fi
if FINISH_BODY="$(awk '/private func finish\(\)/,/^    \}/' "$FILE_DROP")"; then
  grep -q 'autoScroller.stop()' <<<"$FINISH_BODY" \
    || fail "finish 没停心跳：指针离开后时间线会一直自己滚"
  grep -q 'MediaFileDrag.reset()' <<<"$FINISH_BODY" \
    || fail "finish 没清暂存：下一次拖进来会拿上一批文件画框"
fi

# 6) 拖动**过程**中一个字都不写模型（§0）：代理里只有 performDrop 能落地。
NON_DROP="$(awk '/struct MediaFileDropDelegate/,/^\}/' "$FILE_DROP" \
  | awk '/func (validateDrop|dropEntered|dropUpdated|dropExited)\(/,/^    \}/' \
  | grep -nE 'project\.(perform|liveApply|importFiles|addMedia)' || true)"
[ -z "$NON_DROP" ] || fail "文件落点代理在拖动过程中写了模型（只有 performDrop 能落地）：$NON_DROP"

# 6b) 滚动量只许 TimelineScrollGeometry 一处读（§5b）：文件落点自己摸 NSScrollView
#     的话，滚动量就有了第二份账。
if grep -vE '^[[:space:]]*(//|///|\*)' "$FILE_DROP" | grep -c 'NSScrollView' >/dev/null; then
  fail "$FILE_DROP 自己摸 NSScrollView 了：滚动量只许 TimelineScrollGeometry 一处读"
fi

# 7) 探测结果必须对代号：拖出去又拖回来时，回来的是**另一批**文件，
#    旧探测落到新一批身上就是凭空多出几段素材（同 documentGeneration 那条守卫）。
#    判据是「每一个 await 后面都有一道代号校验」，不是数死数 —— await 的个数会变。
PROBE_BODY="$(awk '/private func beginProbe\(\)/,/^    \}/' "$FILE_DROP")"
AWAITS="$(printf '%s\n' "$PROBE_BODY" | grep -c 'await ' || true)"
TOKEN_GUARDS="$(printf '%s\n' "$PROBE_BODY" | grep -c 'MediaFileDrag.pending?.token == token' || true)"
[ "$TOKEN_GUARDS" -ge "$AWAITS" ] && [ "$TOKEN_GUARDS" -ge 1 ] \
  || fail "beginProbe 里 ${AWAITS} 个 await 只配了 ${TOKEN_GUARDS} 道代号校验：拖出去再拖进来会用上一批的时长画框"

# 7b) **这次拖入能不能落，绝不许由探测结果决定**（2026-09-22 首测的回归点）。
#     首测时进场从 `info.itemProviders(for:)` 读 URL —— 松手之前它在 macOS 上
#     经常是空的，于是探测结论「一个能用的都没有」→ 整次拖入被判死，而外层兜底
#     也救不回来（注册已被这一层认领），表现就是**拖进时间线彻底没反应**。
#     三条各自独立：
#     ① 进场读 URL 走拖放剪贴板，不走 itemProviders；
#     ② 「确知不可落」的判据里必须带上「URL 真读到了」这一项；
#     ③ 落地不许因为探测结论而提前返回。
grep -q 'MediaFileDrag.draggedURLs()' <<<"$PROBE_BODY" \
  || fail "beginProbe 没走 draggedURLs（拖放剪贴板）：itemProviders 在松手前经常是空的，整条拖入会静默失效"
if grep -vE '^[[:space:]]*(//|///|\*)' <<<"$PROBE_BODY" | grep -c 'itemProviders' >/dev/null; then
  fail "beginProbe 又去读 itemProviders 了：松手前它经常返回空，这是首测「拖进去没反应」的另一个根因"
fi
grep -q 'var isUnusable: Bool { !isProbing && !urls.isEmpty' "$FILE_DROP" \
  || fail "isUnusable 少了「URL 真读到了」这一项：读不到 URL 会被当成「文件不行」，整条拖入当场变成不可落"
if DROP_BODY3="$(awk '/func performDrop\(info: DropInfo\)/,/^    \}/' "$FILE_DROP")"; then
  grep -q 'isUnusable' <<<"$DROP_BODY3" \
    && fail "performDrop 拿探测结论当闸门：探测本来只为画框和 dropUpdated 的禁止号，拿它决定落不落就会把整次拖入吞掉"
fi

# 8) 落点框只画不吃事件（同第 8 节「块内装饰不吃事件」）：它盖在轨道上，吃掉
#    hit test 就会把落点自己挡住。
if IND_BODY="$(awk '/struct MediaFileDropIndicator/,/^\}/' "$FILE_DROP")"; then
  grep -q 'allowsHitTesting(false)' <<<"$IND_BODY" \
    || fail "MediaFileDropIndicator 没有 allowsHitTesting(false)：会挡住自己的落点"
fi
# 8b) 落点框的**外观只有一份账**：新轨那种「行还不存在」的缩略框，跨轨拖动
#     （crossTrackGhost）和拖文件进来两处必须用同一套几何，各写一份字面量会分叉。
#     四个落点（跨轨拖动的上/下、拖文件进来的上/下）都必须调它，一处写回字面量
#     就少一个 —— 数调用点，别数「某个文件里有没有」（那种写法抓不到偷偷写回的）。
NEW_LANE_CALLS="$(grep -rh 'newLaneY(' Sources/SrtFlow --include='*.swift' \
  | grep -vE '^[[:space:]]*(//|\*)' | grep -v 'static func newLaneY' | wc -l | tr -d ' ')"
[ "$NEW_LANE_CALLS" -eq 4 ] \
  || fail "newLaneY 的调用点有 ${NEW_LANE_CALLS} 处（应为 4：跨轨拖动上/下、拖文件上/下）—— 少一处就是有人写回了字面量"

# 9) ⌘V 两边认的东西必须一致。`paste(_:)` 收的和 `validateMenuItem` 亮的对不上，
#    要么点了没反应，要么明明能粘却是灰的。
if PASTE_BODY="$(awk '/@objc func paste\(_ sender: Any\?\)/,/^    \}/' "$APP_ENTRY")"; then
  grep -q 'pasteMediaFiles()' <<<"$PASTE_BODY" \
    || fail "paste(_:) 不认文件：⌘V 粘贴 Finder 复制的素材会没反应"
fi
if VALIDATE_BODY="$(awk '/func validateMenuItem/,/^    \}/' "$APP_ENTRY")"; then
  grep -q 'MediaFileDrag.pasteboardURLs()' <<<"$VALIDATE_BODY" \
    || fail "validateMenuItem 没把文件算进 Paste 的亮灭：剪贴板里有文件时菜单项仍是灰的"
fi
# 判据必须**同步**：validateMenuItem 等不了异步，所以只能读 NSPasteboard。
# 两个读入口（⌘V 的系统剪贴板、拖放的拖放剪贴板）共用同一个 helper，
# 它一旦变成异步，两边一起坏。
if PB_BODY="$(awk '/private static func urls\(from pasteboard/,/^    \}/' "$FILE_DROP")"; then
  grep -q 'pasteboard.readObjects' <<<"$PB_BODY" \
    || fail "urls(from:) 没走 NSPasteboard 的同步读：validateMenuItem 等不了异步"
  if grep -q 'await' <<<"$PB_BODY"; then
    fail "urls(from:) 里有 await：菜单项的亮灭判据必须同步"
  fi
else
  fail "找不到 urls(from:)（在 ${FILE_DROP}），接线守卫失去目标 —— 改名了就同步改这里"
fi

# 10) 落点算法必须留在**纯值**文件里，不许被挪进拖放那个文件 ——
#     那个文件 import AppKit/SwiftUI，挪过去 scripts/check-media-import.sh 当场编不动。
if grep -qE '^import (AppKit|SwiftUI)' "$MEDIA_IMPORT"; then
  fail "$MEDIA_IMPORT 引入了 AppKit/SwiftUI：落点自检编不动它了（它必须保持纯值）"
fi
grep -q 'func mediaImportLandings' "$MEDIA_IMPORT" \
  || fail "mediaImportLandings 不在 $MEDIA_IMPORT 里了：落点自检会扫空"

# ── 超宽内容：Canvas 只画可见的那一段（2026-09-23 深度缩放） ──────────
# 放大到 4800pt/秒之后，块和标尺能有几百万点宽。SwiftUI 的 Canvas 只光栅化可见条带，
# 却每滚 128pt 就把闭包**整宽**重跑一次：整宽画的话 10M 宽时一次 370ms、内存只涨不退
#（270 → 1080MB）。闭包里必须按 `context.clipBoundingRect` 裁到可见范围
#（docs/architecture/audio-waveform.md）。
grep_code 'context.clipBoundingRect' "$WAVEFORM" \
  || fail "波形没按 clipBoundingRect 裁到可见范围：放大后每滚一下都要把整段重画一遍"
grep_code 'context.clipBoundingRect' "$RULER" \
  || fail "标尺没按 clipBoundingRect 裁到可见范围：放大后每滚一下都要把整条刻度重算一遍"
grep_code 'context.clipBoundingRect' "$THUMBS" \
  || fail "缩略图没按可见范围铺格子：放大之后一张图会被拉成一万多点宽的横缝"
# 缩放滑杆是对数刻度（线性的话原来的整个区间挤在最左 2%），写入仍走唯一入口。
grep_code 'Slider(value: zoomSliderBinding' Sources/SrtFlow/VideoEditView.swift \
  || fail "缩放滑杆不是对数刻度的那个 binding 了"
if BODY="$(awk '/private var zoomSliderBinding/,/^    \}$/' Sources/SrtFlow/VideoEditView.swift)"; then
  grep -q 'setPixelsPerSecond(exp(' <<<"$BODY" \
    || fail "缩放滑杆没走 setPixelsPerSecond（唯一的缩放入口）"
fi
# 波形的数据按文件读一次（多级峰值），不许退回「每段按范围读成固定几百根柱子」——
# 那样放多大都是那几百根，放大只是把每根拉宽（用户报的「放到最大还是不够」）。
grep_code 'WaveformStore.shared.peaks(for:' "$WAVEFORM" \
  || fail "波形没走 WaveformStore（按文件读一次的多级峰值）"

# ── 块上的音量线（2026-09-23） ─────────────────────────────────────────
# 命中区只许是贴着线的窄带 + 点的小圆：整块吃事件的话，拖动 / 裁切 / 框选 / 点选
# 在音频块上全部失灵（docs/architecture/audio-volume-curve.md）。
grep_code 'contentShape(VolumeLineHitShape' "$VOLUME_CURVE" \
  || fail "音量线的命中区不是那条窄带了：整块都会被它吃掉"
# 窄带和点的小圆必须**并**起来（VolumeCurveLayout.hitPath，纯值、有自检）：把圆 append
# 进描边路径的话，重叠处环绕数正负抵消，每个点的正中间都点不中（2026-09-23 案例
# docs/bugfixes/2026-09-23-volume-curve-points-unclickable.md）。
grep_code 'VolumeCurveLayout.hitPath(' "$VOLUME_CURVE" \
  || fail "音量线的命中区没走 VolumeCurveLayout.hitPath（窄带 ∪ 小圆）：自己拼路径会让点的正中间点不中"
# 拖点跟着指针挪同样的量（VolumeCurveLayout.dragging），不许按指针的绝对位置直接搬点：
# 偏着抓的点会在按下后第一拍跳过去（同一案例）。
grep_code 'VolumeCurveLayout.dragging(' "$VOLUME_CURVE" \
  || fail "拖音量线上的点没走 VolumeCurveLayout.dragging：偏着抓的点会跳到指针底下"
# （词边界：removeVolumePoint 里也含这串字母。）
if grep -vE '^[[:space:]]*//' "$VOLUME_CURVE" | grep -cE '(^|[^[:alnum:]_])moveVolumePoint\(' >/dev/null; then
  fail "音量线视图里直接调了 moveVolumePoint（按指针绝对位置搬点）：拖点要走 VolumeCurveLayout.dragging"
fi
# 拖动中不写 TimelineState（§0）：声音靠 previewAudioLive 临时换 mix，松手才落一次。
grep_code 'previewAudioLive' "$VOLUME_CURVE" \
  || fail "拖音量线时没走 previewAudioLive：要么听不见，要么在每一拍写 state"
if grep -vE '^[[:space:]]*//' "$VOLUME_CURVE" | grep -cE 'liveApply|perform[ (]\{|\.perform\(' >/dev/null; then
  fail "音量线在手势里直接写 state 了（liveApply / perform）：拖动中每一拍都会重建整棵视图树"
fi
grep_code 'commitVolumeEdit' "$VOLUME_CURVE" \
  || fail "音量线松手没有落地入口（commitVolumeEdit）"
# 刀片模式下整条让路（点在线上也该落下那一刀）。
grep_code 'allowsHitTesting(project.activeTool == .select)' "$VOLUME_CURVE" \
  || fail "刀片模式下音量线还在吃点击：那一刀落不下去"
# 线挂在波形上（音频块与视频块底部的波形带两处）。
[ "$(grep -c 'VolumeCurveOverlay(' "$CLIP_BLOCK")" -ge 2 ] \
  || fail "音量线没同时挂在音频块和视频块的波形带上"

if [ "$FAILED" -ne 0 ]; then
  exit 1
fi
echo "✓ timeline-drag-wiring：音量线只吃线那一条窄带（窄带 ∪ 小圆）、拖点跟手不跳且拖动中不写 state / 波形 / 标尺 / 缩略图只画可见条带、对数缩放滑杆 / 轨道头对齐与整行点选 / 行高一轨一个值且不进撤销栈 / 文件分工与体积 / 开关默认值 / 播放头把手钉住 / 滚动量现读 / 纵向滚动两处钉住同源 / 动画豁免 / 拖动中不写 state / 输入冻结 / 落点单一 / 三类同一个位移 / 拖框中不写 project / 手势坐标系 / 缩放钳制 / 心跳兜底 / 装饰不吃事件 / 转场遮罩 / 转场拖放接线 / 时间线唯一落点与四套分派 / 文件拖进轨道与 ⌘V 接线 / 滚动内容两轴填满视口 / 命中区盖在填满视口之后 / 点非素材处移播放头与唯一夹紧 / 扫帧 peek 唯一所有者"
