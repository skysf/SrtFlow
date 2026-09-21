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
# 「整族都必须满足」的约束（手势坐标系、文件体积）扫这一批。
MASK="Sources/SrtFlow/VideoEditTimelineTransitionMask.swift"
TIMELINE_VIEWS=("$VIEW" "$MARQUEE_VIEW" "$DRAG_WIRING" "$CLIP_BLOCK" "$SHAPE_ROW" \
  "$TEXT_ROW" "$SUBTITLE_ROW" "$RULER" "$THUMBS" "$WAVEFORM" "$ZOOM" "$GEOMETRY" \
  "$HEADER_COLUMN" "$MASK")
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
  grep -n "$1" "$2" | grep -vE '^[0-9]+:[[:space:]]*//' | grep -q .
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
  echo "$ANIM" | grep -q 'isTrimming' || fail "剪辑块的 .animation 没豁免裁切中的块（isTrimming）：$ANIM"
  echo "$ANIM" | grep -q 'dragOffset' || fail "剪辑块的 .animation 没豁免拖动中的块（dragOffset）：$ANIM"
fi

# ── 2. 拖动过程中一个字都不许写进 TimelineState ────────────────────────
# 每一拍改 state 会连带整个编辑器视图树重建 + 重挂自动保存，mouseDragged
# 随即积压，块就追不上光标了。
if UPDATE_BODY="$(require_func 'func updateClipDrag' "$DRAG_WIRING")"; then
  for forbidden in 'liveApply' 'liveMove' 'commitDrag' 'commitFreeDrag' 'relocate' 'project.perform'; do
    printf '%s\n' "$UPDATE_BODY" | grep -q "$forbidden" \
      && fail "updateClipDrag 里出现了 ${forbidden}：拖动中禁止写 TimelineState"
  done
  # 候选/障碍必须在手势开始时冻住：拖动中重算 = 跟着动的伙伴又变回参考点（粘手）。
  printf '%s\n' "$UPDATE_BODY" | grep -q 'snapCandidates\|TimelineSnap.candidates\|dragPlan(' \
    && fail "updateClipDrag 里重算了冻结输入：候选/障碍只能在 begin 时取一次"
fi

# ── 3. 一轮拖动的输入必须在手势开始时冻结 ──────────────────────────────
for entry in 'func beginClipDrag' 'func beginShapeDrag' 'func beginCueDrag'; do
  if BODY="$(require_func "$entry" "$DRAG_WIRING")"; then
    printf '%s\n' "$BODY" | grep -q '[dD]ragPlan(' \
      || fail "${entry} 没有冻结这一轮的输入（dragPlan/shapeDragPlan）"
  fi
done
# 三个入口的「跟着动的名单」必须都走那份纯值规则：链接组要为**每一个**多选
# 成员各展开一次（只展开被拖的那个 = 另一段的音频留在原地，A/V 错位），
# 磁吸下主轨成员要整批剔除（平了也会被 packMain 排回去 = 拖动中骗人）。
for entry in 'func movingClipIDs(draggedID' 'func shapeDragPlan(shapeID' 'func cueDragPlan(cueID'; do
  if BODY="$(require_func "$entry" "$PROJECT")"; then
    printf '%s\n' "$BODY" | grep -q 'draggingClipIDs(' \
      || fail "${entry} 没走 TimelineState.draggingClipIDs：链接组/磁吸剔除的规则会各写一份"
    printf '%s\n' "$BODY" | grep -q 'linkedClipIDs(' \
      && fail "${entry} 自己展开了链接组：规则只能有一份（draggingClipIDs）"
  fi
done
if BODY="$(require_func 'func draggingClipIDs(' "$EDITS")"; then
  printf '%s\n' "$BODY" | grep -q 'for id in seed' \
    || fail "draggingClipIDs 没有为每一个多选成员展开链接组：另一段的音频会留在原地"
  printf '%s\n' "$BODY" | grep -q 'magnetPinsMainTrack' \
    || fail "draggingClipIDs 丢了磁吸剔除主轨成员那条"
fi
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
for entry in 'func commitDrag' 'func commitFreeDrag'; do
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
  printf '%s\n' "$BODY" | grep -q 'move(plan.members' \
    || fail "applyDrag 没有整组平移：跟随块会被落在旧时刻（A/V 错位）"
  printf '%s\n' "$BODY" | grep -q 'resolution.delta' \
    || fail "applyDrag 没有用整组统一的 resolution.delta"
  printf '%s\n' "$BODY" | grep -q 'resolution.mainInsertion' \
    || fail "applyDrag 没有用拖动中算好的 mainInsertion：主轨插入指示线会说谎"
  # 落点可能不等于 resolution.delta（磁吸插空、跨轨到岸让位），伙伴必须按
  # **实际**位移再平一次，否则整组相对位置被拆散、链接音频当场 A/V 错位。
  printf '%s\n' "$BODY" | grep -q 'realignCompanions' \
    || fail "applyDrag 没有按实际落点重平伙伴：跨轨/磁吸落地会拆散整组"
  # 磁吸重排必须在 applyDrag 里做完：perform 之后还会排一次，这里不排的话
  # 自检在纯值层看到的就不是最终位置（复审指出的假绿）。
  printf '%s\n' "$BODY" | grep -q 'if magnet { packMain() }' \
    || fail "applyDrag 没有在磁吸时自己 packMain：自检看到的落点不是最终落点"
fi
if BODY="$(require_func 'private mutating func realignCompanions' "$EDITS")"; then
  printf '%s\n' "$BODY" | grep -q 'plan.draggedSpan.start' \
    || fail "realignCompanions 没按「被拖块实际落点 - 冻结起点」算位移"
  printf '%s\n' "$BODY" | grep -q 'Set(mainClips.map' \
    || fail "realignCompanions 没把磁吸下的主轨成员排除：它们由 packMain 定位"
  # 被 packMain 排走的主轨块，它的链接伙伴要跟着**它**走，不是跟着整组的 delta。
  # 少了这条：把一段主轨块拖去别的轨，磁吸合拢主轨，留下的视频挪了、它分离出来的
  # 音频没挪 —— 声画错开一整段。
  printf '%s\n' "$BODY" | grep -q 'linkedClipIDs(' \
    || fail "realignCompanions 没让链接伙伴跟随被排走的主轨块：跨轨会声画错位"
fi
# 跨轨到岸让位不许把整组顶过下界（伙伴会各自被 max(0,…) 夹住，相对错位压扁）。
if BODY="$(require_func 'mutating func applyDrag' "$EDITS")"; then
  printf '%s\n' "$BODY" | grep -q 'groupLowerDelta' \
    || fail "applyDrag 跨轨落地没传整组下界：往左让位会压扁相对错位"
fi
if BODY="$(require_func 'func clampedStart(' "$EDITS")"; then
  printf '%s\n' "$BODY" | grep -q 'notBefore' \
    || fail "clampedStart 没有下界参数：跨轨让位会越过整组能去的最左边"
fi

# ── 4b. 三类成员共用同一个位移，且写第二次必须幂等 ─────────────────────
# 框选能一次选中剪辑 + 形状 + 字幕 cue。三类改的字段不同，位移只能有一个；
# 落点一律按「冻结的 span + delta」算**绝对值** —— 磁吸主轨那条分支会拿实际
# 落点把非主轨成员再平一次，叠加式的写法在那里就是双倍位移。
if BODY="$(require_func 'private mutating func move(' "$EDITS")"; then
  printf '%s\n' "$BODY" | grep -q 'member.span.start + delta' \
    || fail "move 没按「冻结 span + delta」算绝对落点：磁吸那条分支会变成双倍位移"
  for kind in '.clip' '.shape' '.subtitleCue'; do
    printf '%s\n' "$BODY" | grep -q "case ${kind}" \
      || fail "move 漏了 ${kind} 这一类成员：框选中的它不会跟着一起动"
  done
  printf '%s\n' "$BODY" | grep -q 'LinkedSubtitleEditing.setStarts' \
    || fail "字幕 cue 没走两轨同步的合同：译文会留在旧时刻"
fi

# ── 4c. 框选：拖框过程中一个字都不许写进 project ───────────────────────
# 和拖块同一条约束。每一拍写 @Published 的选择会连带预览区、检查器、所有块
# 连同缩略图与波形重建，还要重挂一次自动保存，框立刻跟不上光标。
for entry in 'private func updateMarquee' 'private func applyMarqueePoint'; do
  if BODY="$(require_func "$entry" "$MARQUEE_VIEW")"; then
    for forbidden in 'applyBoxSelection' 'project.select' 'clearSelection' 'project.perform' 'liveApply'; do
      printf '%s\n' "$BODY" | grep -q "$forbidden" \
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
    printf '%s\n' "$line" | grep -q 'coordinateSpace: \.named(VideoEditTimelineView\.scrollSpace)' \
      || fail "移动手势没钉在滚动视口坐标系上：$line"
  done <<< "$GESTURE"
fi
# 三类块都要真的把移动手势接上：剪辑、形状、字幕 cue。少一类，「拖任意一个被
# 选中的东西，整片跟着走」对那一类就是空话 —— cue 就这么漏过一轮（复审第 3 条）。
# 不用「数手势个数」：容器上还挂着拉框手势，数得出来的绿是假绿。
if BODY="$(require_func 'func subtitleRow' "$SUBTITLE_ROW")"; then
  printf '%s\n' "$BODY" | grep -q 'DragGesture(minimumDistance: 4' \
    || fail "字幕 cue 块没有移动手势：从 cue 起手拖不动整组"
  printf '%s\n' "$BODY" | grep -q 'beginCueDrag(' \
    || fail "字幕 cue 的手势没冻结这一轮的输入（beginCueDrag）"
  printf '%s\n' "$BODY" | grep -q 'endClipDrag(' \
    || fail "字幕 cue 的手势没有落地入口（endClipDrag）"
  # 隐藏 = 不可编辑（与 trackRow 同一条合同）。只灰显不挡事件的话，隐藏的字幕行
  # 照样拖得动，而且改的是**两条**镜像轨的时间。
  printf '%s\n' "$BODY" | grep -q 'allowsHitTesting(!hidden)' \
    || fail "字幕行隐藏后仍然吃事件：隐藏轨必须不可编辑"
  # 起手判据要带上「有没有活着的会话」，否则被打断后留下的陈旧 id 会让同一条 cue
  # 的下一次拖动整轮建不出会话。
  printf '%s\n' "$BODY" | grep -q 'clipDrag == nil || movingCueID != cue.id' \
    || fail "cue 起手只比了 id：手势被打断后同一条 cue 会失效一次"
fi
# 视图消失时，手势的所有残留状态都要清干净（会话 + 起手标记）。
if BODY="$(extract_func '.onDisappear {' "$VIEW")"; then
  printf '%s\n' "$BODY" | grep -q 'movingCueID = nil' \
    || fail "onDisappear 没清 movingCueID：下一次拖同一条 cue 会失效一次"
fi
grep -q 'onDragBegin: { beginShapeDrag(shape) }' "$SHAPE_ROW" \
  || fail "形状块没有接上 beginShapeDrag"
grep -q 'beginClipDrag(' "$VIEW" || fail "剪辑块没有接上 beginClipDrag"

# ── 5b. 框选的纵向命中必须按「画出来的块」算，不是整行 ─────────────────
# 字幕/形状块在行内上下都留了白，按整行判的话框从留白里扫过也会选中。
if BODY="$(require_func 'private func marqueeRows' "$MARQUEE_VIEW")"; then
  for constant in 'shapeTopInset' 'shapeHeight' 'cueTopInset' 'cueHeight'; do
    printf '%s\n' "$BODY" | grep -q "TimelineMarquee.${constant}" \
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
grep -n 'pixelsPerSecond.wrappedValue = ' "$ZOOM" | grep -vq 'clamped' \
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
    printf '%s\n' "$BODY" | grep -q 'allowsHitTesting(false)' \
      || fail "${DECO_NAME} 没有 allowsHitTesting(false)：scaledToFill 的隐形溢出会把标尺/空白变成块的命中区"
  fi
done
if BODY="$(extract_func 'private var keyframeMarkers' "$CLIP_BLOCK")"; then
  printf '%s\n' "$BODY" | grep -q 'allowsHitTesting(false)' \
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
    printf '%s\n' "$BODY" | grep -q 'scrollGeometry\.offsetX' \
      || fail "${entry} 没有现读滚动量（scrollGeometry.offsetX）：框会偏出一个滚动量"
  fi
done
# 9c. 四个拖动入口冻结的「起手滚动量」同样现读 —— 那个值和自动滚动中的现读值
# 相减，差一点点就是块在自动滚动开始那一瞬间猛跳一段。
COUNT="$(grep -c 'originScrollOffset: scrollGeometry\.offsetX' "$DRAG_WIRING" || true)"
[ "$COUNT" -eq 4 ] \
  || fail "拖动入口只有 ${COUNT} 处现读起手滚动量，应当 4 处（剪辑/形状/文字/字幕）"
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
  printf '%s\n' "$BODY" | grep -q 'Color.clear' \
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
  printf '%s\n' "$BODY" | grep -q 'dx == 0 ? current.x' \
    || fail "scroll(dx:dy:) 把没在推的那一轴也夹了：纵向自动滚动那一拍会横着跳"
  printf '%s\n' "$BODY" | grep -q 'dy == 0 ? current.y' \
    || fail "scroll(dx:dy:) 把没在推的那一轴也夹了：横向自动滚动那一拍会竖着跳"
fi
# 框选的两个端点在**两个轴**上都要补滚动量。
for entry in 'private func beginMarquee' 'private func applyMarqueePoint'; do
  if BODY="$(require_func "$entry" "$MARQUEE_VIEW")"; then
    printf '%s\n' "$BODY" | grep -q 'scrollGeometry\.offsetY' \
      || fail "${entry} 没补纵向滚动量：滚下去之后框会整体偏出一个纵向滚动量"
  fi
done
# 跨轨判定要按「此刻露出来的是哪几条轨」算（纵向自动滚动期间指针不动、内容在滚）。
if BODY="$(require_func 'func verticalTarget(' "$DRAG_WIRING")"; then
  printf '%s\n' "$BODY" | grep -q 'originScrollOffsetY' \
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
  printf '%s\n' "$BODY" | grep -q 'frame(width: 9, height: 14)' \
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
            'TimelineHeaderMetrics.eyeWidth'; do
  grep_code "frame(width: ${cell})" "$HEADER_COLUMN" \
    || fail "轨道头少了固定宽度的那一格（${cell}）：这一列又会一行一个样"
done
# 没有色条/没有眼睛的行也必须占着那一格，否则那几行整体左移。
if BODY="$(require_func 'private var eye: some View' "$HEADER_COLUMN")"; then
  printf '%s\n' "$BODY" | grep -q 'Color.clear' \
    || fail "没有眼睛的行没占住眼睛那一格：它的图标会跑到别人眼睛的位置上"
fi
# 点选：轨道头点一下选中整行，判据只有 TimelineRowSelection 一份。
grep_code 'project.selectRow(' "$HEADER_COLUMN" \
  || fail "轨道头没接上点选：点非眼睛的地方应当选中这一行的全部素材"
grep_code 'selectedClipIDs\|selectedShapeIDs\|selectedTextIDs\|selectedSubtitleCueIDs' "$HEADER_COLUMN" \
  && fail "轨道头自己写选择了：只能走 project.selectRow（判据留在 TimelineRowSelection）"
if BODY="$(require_func 'func selectRow(' "$ROW_SELECT_ENTRY")"; then
  printf '%s\n' "$BODY" | grep -q 'TimelineRowSelection.ids(' \
    || fail "selectRow 没走纯值 TimelineRowSelection.ids：那份判据自检就够不着了"
  printf '%s\n' "$BODY" | grep -q 'guard !result.isEmpty else { return }' \
    || fail "selectRow 少了空行早退：点空轨会把用户已有的选择抹掉"
fi
# 眼睛必须还是 Button：它自己把点击吃掉，才不会连带触发整行点选。
if BODY="$(require_func 'private func eyeButton(' "$HEADER_COLUMN")"; then
  printf '%s\n' "$BODY" | grep -q 'Button(action: action)' \
    || fail "眼睛不是 Button 了：点眼睛会连带把整条轨的素材选中"
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
  printf '%s\n' "$MASK_EDGE" | grep -q 'dragStartDuration == nil' \
    || fail "转场遮罩的拖动没有在开始时定死时长（dragStartDuration）：磁吸重排会让它自己追自己"
fi

# 落值必须被容量夹住。拖得出一个渲染管线做不出来的时长，就又回到了
# 「设了但成片里没有」——那正是 2026-09-20 那次事故的形状。
if MASK_APPLY="$(require_func 'private func apply(duration:' "$MASK")"; then
  printf '%s\n' "$MASK_APPLY" | grep -q 'maxDuration' \
    || fail "转场遮罩落值时没有按容量夹紧：能拖出渲染管线做不出来的时长"
fi


# ── 滚动内容必须填满视口、顶对齐 ──────────────────────────────────────
# 轨道少的时候（常态）内容比视口矮，不撑满的话 SwiftUI 会把它**纵向居中**，
# 连出两个 bug（2026-09-20 用户报的）：
#   1. 播放头那条线只画在居中后那一段，上面接不到标尺 —— 「指针是断的」；
#   2. 标尺靠 `.offset(y: geometry.offset.y)` 被拉回视口顶上，但它的**命中区
#      没跟过去**，点可见的标尺 seek 不了 —— 「播放头没法移动」。
# 两个症状同一个根。修法就是这一行 minHeight。
if SCROLL_BLOCK="$(grep -A 12 'ScrollView(\[\.horizontal, \.vertical\]' "$VIEW" || true)"; then
  # 两个条件写在**同一行**上匹配：分开写的话 `alignment: .top` 会被上一行的
  # `.topLeading` 顺手匹配掉，顶对齐那条就成了永远为真的假绿。
  printf '%s\n' "$SCROLL_BLOCK" | grep -q 'minHeight: viewportHeight, alignment: \.top)' \
    || fail "时间线滚动内容没有 .frame(minHeight: viewportHeight, alignment: .top)：内容比视口矮时会被纵向居中，播放头的线会断、标尺点不动"
fi

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

# 2) 落点：挂在**主轨那一行**上，靠 slot.isMain 把纵向合法性天然判掉。
[ "$(drag_hits "$VIEW" 'of: slot\.isMain && !hidden \? \[TransitionDrag\.type\] : \[\]')" -ne 0 ] \
  || fail "主轨行没挂转场落点，或没按 slot.isMain 限定：拖到字幕轨/形状轨上也会接"
[ "$(drag_hits "$VIEW" 'delegate: TransitionDropDelegate\(')" -ne 0 ] \
  || fail "落点没走 DropDelegate：.dropDestination 的 isTargeted 只给 Bool，画不出落点框"

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
  printf '%s\n' "$DROP_BODY" | grep -qE 'let target = target\(info\)' \
    || fail "performDrop 没有用 target(info) 重算落点：读 @State 会和画框那一拍脱节"
fi

# 6) 落点框只画不吃事件：它盖在主轨上，吃掉 hit test 就会把落点自己挡住
#    （同第 8 节「块内装饰不吃事件」的理由）。
if IND_BODY="$(awk '/struct TransitionDropIndicator/,0' "$DRAG")"; then
  printf '%s\n' "$IND_BODY" | grep -q 'allowsHitTesting(false)' \
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
  printf '%s\n' "$EXIT_BODY" | grep -q 'autoScroller.stop()' \
    || fail "dropExited 没停心跳：指针离开后时间线会一直自己滚"
fi
if DROP_BODY2="$(awk '/func performDrop\(info: DropInfo\)/,/^    \}/' "$DRAG")"; then
  printf '%s\n' "$DROP_BODY2" | grep -q 'autoScroller.stop()' \
    || fail "performDrop 没停心跳：松手后时间线会一直自己滚"
fi

# 11) **只横着滚**。转场只落在主轨那一行，纵向滚下去反而把主轨滚出视口、落点当场
#     消失。传 height: 0 让心跳的纵向那一半整个跳过。
[ "$(drag_hits "$DRAG" 'viewport: CGSize\(width: viewport\.width, height: 0\)')" -ne 0 ] \
  || fail "转场落点的自动滚动没限定成只横向：纵向滚动会把主轨滚出视口"

# 12) 视口坐标靠**现读**的滚动量换算（§5b 同一条）。缓存一份的话，自动滚动期间
#     指针在视口里的位置会越算越偏，边缘带自己就飘走了。
if SCROLL_BODY="$(awk '/private func autoScroll\(contentX: Double\)/,/^    \}/' "$DRAG")"; then
  printf '%s\n' "$SCROLL_BODY" | grep -qc 'geometry.offsetX' >/dev/null
  [ "$(printf '%s\n' "$SCROLL_BODY" | grep -c 'geometry.offsetX')" -ge 2 ] \
    || fail "autoScroll 没有两处现读 geometry.offsetX（换算视口坐标一处、滚动后重算一处）"
fi

# 8) 点一张卡和拖一张卡必须走同一条落地路径，否则同一个动作两个入口两种结果。
[ "$(drag_hits "Sources/SrtFlow/VideoEditProject+TransitionLibrary.swift" 'func applyTransition\(toSeamAfter outgoingID: UUID')" -ne 0 ] \
  || fail "没有共用的 applyTransition(toSeamAfter:_:)：点卡片和拖卡片会分叉"
[ "$(drag_hits "Sources/SrtFlow/VideoEditProject+TransitionLibrary.swift" 'applyTransition\(toSeamAfter: seam\.outgoing\.id')" -ne 0 ] \
  || fail "applyTransitionFromLibrary 没走共用落地函数"

if [ "$FAILED" -ne 0 ]; then
  exit 1
fi
echo "✓ timeline-drag-wiring：轨道头对齐与整行点选 / 文件分工与体积 / 开关默认值 / 播放头把手钉住 / 滚动量现读 / 纵向滚动两处钉住同源 / 动画豁免 / 拖动中不写 state / 输入冻结 / 落点单一 / 三类同一个位移 / 拖框中不写 project / 手势坐标系 / 缩放钳制 / 心跳兜底 / 装饰不吃事件 / 转场遮罩 / 转场拖放接线 / 滚动内容填满视口"
