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
# 「整族都必须满足」的约束（手势坐标系、文件体积）扫这一批。
TIMELINE_VIEWS=("$VIEW" "$MARQUEE_VIEW" "$DRAG_WIRING" "$CLIP_BLOCK" "$SHAPE_ROW" \
  "$TEXT_ROW" "$SUBTITLE_ROW" "$RULER" "$THUMBS" "$WAVEFORM" "$ZOOM" "$GEOMETRY")
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

if [ "$FAILED" -ne 0 ]; then
  exit 1
fi
echo "✓ timeline-drag-wiring：文件分工与体积 / 滚动量现读 / 动画豁免 / 拖动中不写 state / 输入冻结 / 落点单一 / 三类同一个位移 / 拖框中不写 project / 手势坐标系 / 缩放钳制 / 心跳兜底 / 装饰不吃事件"
