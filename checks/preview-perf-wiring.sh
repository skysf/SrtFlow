#!/usr/bin/env bash
# 扫描守卫：预览性能测试的计数必须接满（docs/architecture/preview-perf-ratchet.md）。
#
# CI 上卡的是「做了多少件活」（PerfCounters）：哪个视图的 body 被重算了几次、
# updateNSView 被调了几次、Canvas 画了几次。**漏插一个，那个视图每跳一下都在重算，
# 账上也看不见** —— 性能测试照样绿，ratchet 就成了摆设。所以：
#
# 1. 每个 SwiftUI 视图 / 修饰器的 body 下一行必须是 `let _ = PerfCounters.body(Self.self)`；
# 2. 视图 / 修饰器的个数必须等于标准写法的 body 个数 —— 把 body 写成一行、或者换了
#    写法，第 1 条就扫不到它，这里直接判红（请写成标准形式）；
# 3. 每个 `updateNSView` 下一行是 `PerfCounters.update(Self.self)`，个数和
#    NSViewRepresentable 对得上；每个 Canvas 的绘制闭包第一行是 `PerfCounters.canvas(Self.self)`；
# 4. 视图不许重名：计数按类型名记账，重名就串成一笔；
# 5. 非视图的几处埋点和测试入口都还接着。
#
# 用法：
#   checks/preview-perf-wiring.sh          # 检查（check-all 第 1 组）
#   checks/preview-perf-wiring.sh --fix    # 先把漏插的计数自动补上，再检查
#
# `--fix` 只补**标准写法**：body 开头独占一行、`updateNSView` 的签名在同一行、
# `Canvas { … in` 写在同一行。别的写法（body 写成一行、Canvas 开头跨行）不去猜 ——
# 猜错了会把计数插进参数列表里，编都编不过 —— 照样判红，改成标准写法再跑。
set -euo pipefail
cd "$(dirname "$0")/.."

FIX=0
case "${1:-}" in
  --fix) FIX=1 ;;
  "") ;;
  *) echo "✗ 不认识的参数：$1（用法见文件开头）" >&2; exit 2 ;;
esac

# 用文件系统枚举，不用 git ls-files：新文件还没 add 时会被静默跳过。
SWIFT_FILES=$(find Sources/SrtFlow -name '*.swift' -type f | sort)
fail=0

BODY_OPENER='^[[:space:]]+var body: some View \{$'
MODIFIER_OPENER='^[[:space:]]+func body\(content: Content\) -> some View \{$'
UPDATE_OPENER='^[[:space:]]+func updateNSView\(.*\) \{$'
# 以 Canvas 开头的闭包：前面不许紧挨标识符字符（ShapeOverlayCanvas( 那种是视图名，不算）。
CANVAS_OPENER='(^|[^A-Za-z0-9_])Canvas[ ]?[({]'
# `--fix` 只补闭包头写在同一行的 Canvas（行尾是 `in`）。
CANVAS_FIXABLE='(^|[^A-Za-z0-9_])Canvas[ ]?[({].* in$'

# 把漏插的计数补在开头行下面，缩进比开头行多四格。只在真插了东西时才写回文件
# （awk 会给结尾没有换行的文件补一个换行，没插东西也写回就成了平白的改动）。
fix_missing() {
  local file tmp status
  for file in $SWIFT_FILES; do
    tmp="$(mktemp)"
    status=0
    BODY="$BODY_OPENER" MODIFIER="$MODIFIER_OPENER" UPDATE="$UPDATE_OPENER" CANVAS="$CANVAS_FIXABLE" awk '
      function counter_for(line) {
        if (line ~ /^[[:space:]]*\/\//) return ""
        if (line ~ ENVIRON["BODY"] || line ~ ENVIRON["MODIFIER"]) return "let _ = PerfCounters.body(Self.self)"
        if (line ~ ENVIRON["UPDATE"]) return "PerfCounters.update(Self.self)"
        if (line ~ ENVIRON["CANVAS"]) return "PerfCounters.canvas(Self.self)"
        return ""
      }
      function emit(line, following, has_following,    want, lead) {
        print line
        want = counter_for(line)
        if (want == "") return
        if (has_following && index(following, want) > 0) return
        match(line, /^[ \t]*/)
        lead = substr(line, 1, RLENGTH)
        print lead "    " want
        inserted = 1
      }
      NR > 1 { emit(previous, $0, 1) }
      { previous = $0 }
      END {
        if (NR > 0) emit(previous, "", 0)
        exit inserted ? 10 : 0
      }
    ' "$file" > "$tmp" || status=$?
    if [ "${status}" -eq 10 ]; then
      cat "$tmp" > "$file"
      echo "    补上了：$file"
    elif [ "${status}" -ne 0 ]; then
      rm -f "$tmp"
      echo "✗ 自动补 $file 时 awk 出错（退出码 ${status}）" >&2
      exit 1
    fi
    rm -f "$tmp"
  done
}

if [ "${FIX}" -eq 1 ]; then
  echo "==> 自动补漏插的计数"
  fix_missing
fi

# 下一行必须是 <want> 的开头行（awk：逐文件记住「上一行是开头」）。
# $1 开头行的正则，$2 下一行必须完全匹配的正则，$3 人话
next_line_must_be() {
  local label="$3" bad
  # 正则走环境变量传进 awk：`awk -v` 会先处理反斜杠转义，`\(` 变成 `(`，正则就错了。
  # shellcheck disable=SC2086
  bad=$(OPENER="$1" WANT="$2" awk '
    FNR == 1 { expect = 0 }
    expect {
      if ($0 !~ ENVIRON["WANT"]) printf "    %s:%d\n", FILENAME, FNR - 1
      expect = 0
    }
    $0 ~ ENVIRON["OPENER"] && $0 !~ /^[[:space:]]*\/\// { expect = 1 }
  ' $SWIFT_FILES)
  if [ -n "${bad}" ]; then
    echo "✗ ${label}，这几处下一行不是计数："
    printf '%s\n' "${bad}"
    fail=1
  fi
}

# 数某个正则在全部文件里的匹配行数（去掉注释行）。
count_lines() {
  # shellcheck disable=SC2086
  { grep -hE "$1" $SWIFT_FILES || true; } | { grep -vE '^[[:space:]]*//' || true; } | wc -l | tr -d ' '
}

echo "==> body 第一行是计数"
next_line_must_be "$BODY_OPENER" '^[[:space:]]+let _ = PerfCounters\.body\(Self\.self\)$' "视图 body"
next_line_must_be "$MODIFIER_OPENER" '^[[:space:]]+let _ = PerfCounters\.body\(Self\.self\)$' "修饰器 body"
next_line_must_be "$UPDATE_OPENER" '^[[:space:]]+PerfCounters\.update\(Self\.self\)$' "updateNSView"
next_line_must_be "$CANVAS_OPENER" '^[[:space:]]+PerfCounters\.canvas\(Self\.self\)$' \
  "Canvas 绘制闭包（闭包头 \`Canvas { context, size in\` 要写在同一行，--fix 才补得上）"

echo "==> 视图个数和标准 body 个数对得上"
VIEW_DECL='^(private |fileprivate )?struct [A-Za-z0-9_]+(<[^>]*>)?: ([A-Za-z0-9_.]+, )*View([ ,{]|$)'
MODIFIER_DECL='^(private |fileprivate )?struct [A-Za-z0-9_]+(<[^>]*>)?: ([A-Za-z0-9_.]+, )*ViewModifier([ ,{]|$)'
REPRESENTABLE_DECL='^(private |fileprivate )?struct [A-Za-z0-9_]+(<[^>]*>)?: ([A-Za-z0-9_.]+, )*NSViewRepresentable([ ,{]|$)'
views=$(count_lines "$VIEW_DECL")
modifiers=$(count_lines "$MODIFIER_DECL")
representables=$(count_lines "$REPRESENTABLE_DECL")
bodies=$(count_lines "$BODY_OPENER")
modifier_bodies=$(count_lines "$MODIFIER_OPENER")
updates=$(count_lines "$UPDATE_OPENER")
# 扫了个空（路径、写法全变了）也是绿的 —— 先钉一个下限。
if [ "${views}" -lt 50 ]; then
  echo "✗ 只扫到 ${views} 个视图，守卫多半扫空了（Sources/SrtFlow 里应该有 90 个上下）"
  fail=1
fi
if [ "${views}" != "${bodies}" ]; then
  echo "✗ 有 ${views} 个视图，标准写法的 body（var body: some View {）只有 ${bodies} 个："
  echo "  有视图的 body 换了写法（写成一行？），第一条扫不到它。请写成标准形式。"
  fail=1
fi
if [ "${modifiers}" != "${modifier_bodies}" ]; then
  echo "✗ 有 ${modifiers} 个修饰器，标准写法的 body（func body(content: Content) -> some View {）只有 ${modifier_bodies} 个"
  fail=1
fi
if [ "${representables}" != "${updates}" ]; then
  echo "✗ 有 ${representables} 个 NSViewRepresentable，标准写法的 updateNSView 只有 ${updates} 个"
  fail=1
fi
echo "    视图 ${views}、修饰器 ${modifiers}、NSViewRepresentable ${representables}"

echo "==> 视图不重名"
# shellcheck disable=SC2086
dupes=$({ grep -hE "$VIEW_DECL|$MODIFIER_DECL|$REPRESENTABLE_DECL" $SWIFT_FILES || true; } \
  | sed -E 's/^(private |fileprivate )?struct ([A-Za-z0-9_]+).*/\2/' | sort | uniq -d)
if [ -n "${dupes}" ]; then
  echo "✗ 这几个视图重名了（计数按类型名记账，会串成一笔）：${dupes}"
  fail=1
fi

echo "==> 非视图的埋点和测试入口"
need() {   # need <文件> <正则> <人话>
  if [ ! -f "$1" ]; then echo "✗ 文件不在：$1"; fail=1; return; fi
  if ! grep -cE "$2" "$1" >/dev/null; then
    echo "✗ $1 少了 $3（模式 /$2/）"
    fail=1
  fi
}
need Sources/SrtFlow/VideoPreviewView.swift 'self\?\.observePlaybackTime\(cmTime\.seconds\)' '播放器的时间回调走 observePlaybackTime（测试的时钟连跳也走它）'
need Sources/SrtFlow/VideoPreviewView.swift 'PerfCounters\.event\(\.clockTick\)' '时钟每跳一下的计数'
need Sources/SrtFlow/VideoPreviewView.swift 'PerfCounters\.event\(\.playerItemAttach\)' '换播放条目的计数'
need Sources/SrtFlow/VideoEditCompositionBuilder.swift 'PerfCounters\.event\(\.compositionBuild\)' '建合成的计数'
need Sources/SrtFlow/VideoEditCompositionBuilder.swift 'PerfCounters\.event\(\.compositionAssetOpen\)' '开素材文件的计数'
need Sources/SrtFlow/VideoEditAudioMeter.swift 'PerfCounters\.event\(\.meterTapCreate\)' '新建电平表 tap 的计数'
need Sources/SrtFlow/VideoEditProject.swift 'PerfCounters\.event\(\.audioMixRefresh\)' 'audioMix 快路径的计数'
# 编辑器出现时的开发钩子收在 DevHooks.editorAppeared 里（2026-09-24 从 VideoEditView 挪出去）：
# 钉住两头 —— 视图调了钩子、钩子里启动了性能测试。
need Sources/SrtFlow/VideoEditView.swift 'DevHooks\.editorAppeared\(project: project\)' '编辑器出现时调开发钩子'
need Sources/SrtFlow/DevHooks.swift 'PreviewBench\.startIfRequested\(project: project\)' '开发钩子里启动性能测试的入口'
# 后台读媒体的起止：少了它，测试会在缩略图 / 波形还没读完时就开始量，数时有时无。
need Sources/SrtFlow/VideoEditTimelineThumbnails.swift 'PerfCounters\.backgroundReadBegan\(\)' '缩略图开始取图的登记'
need Sources/SrtFlow/VideoEditTimelineThumbnails.swift 'PerfCounters\.backgroundReadEnded\(\)' '缩略图取完的登记'
need Sources/SrtFlow/VideoEditWaveformData.swift 'PerfCounters\.backgroundReadBegan\(\)' '波形开始解码的登记'
need Sources/SrtFlow/VideoEditWaveformData.swift 'PerfCounters\.backgroundReadEnded\(\)' '波形解码完的登记'

echo "==> 时间线上的块：不读工程、按值比较"
# 块读了工程的属性，就订阅了那个属性（工程是 @Observable，2026-09-25 起）：读 `selection` 就是
# 「点选一段全部块重算」，读 `state` 就是「改任何一处全部块重算」；块的输入里带闭包，SwiftUI 比不出
# 「没变」，时间线每重算一次全部块也都跟着重算。所以块只收算好的值（`ClipBlockContext`）、自己实现
# `==`、调用处套 `.equatable()`。三条都钉住：docs/architecture/preview-perf-ratchet.md「时间线上的块」，
# 案例 docs/bugfixes/2026-09-24-timeline-blocks-observe-whole-project.md。
#（换 Observation 之前第二条钉的是「没有 @ObservedObject var project」，那种写法现在编不过了。）
# 格式：<块所在文件>|<视图名>|<构造它的文件>
for spec in \
  'Sources/SrtFlow/VideoEditTimelineClipBlock.swift|ClipBlockView|Sources/SrtFlow/VideoEditTimelineView.swift' \
  'Sources/SrtFlow/VideoEditTimelineTextRow.swift|TextBlockView|Sources/SrtFlow/VideoEditTimelineTextRow.swift' \
  'Sources/SrtFlow/VideoEditTimelineShapeRow.swift|ShapeBlockView|Sources/SrtFlow/VideoEditTimelineShapeRow.swift' \
  'Sources/SrtFlow/VideoEditTimelineFilterRow.swift|FilterBlockView|Sources/SrtFlow/VideoEditTimelineFilterRow.swift' \
  'Sources/SrtFlow/VideoEditTimelineSubtitleCueBlock.swift|SubtitleCueBlockView|Sources/SrtFlow/VideoEditTimelineSubtitleRow.swift' \
  'Sources/SrtFlow/VideoEditTimelineRuler.swift|TimelinePinnedRuler|Sources/SrtFlow/VideoEditTimelineView.swift' \
  'Sources/SrtFlow/VideoEditTimelineVolumeCurve.swift|VolumeCurveOverlay|Sources/SrtFlow/VideoEditTimelineClipBlock.swift' \
  'Sources/SrtFlow/VideoEditTransitionPicker.swift|TransitionCard|Sources/SrtFlow/VideoEditTransitionPicker.swift'; do
  IFS='|' read -r file view host <<<"$spec"
  if [ ! -f "$file" ] || [ ! -f "$host" ]; then echo "✗ 文件不在：$file / $host"; fail=1; continue; fi
  if ! grep -cE "struct ${view}: View, Equatable" "$file" >/dev/null; then
    echo "✗ ${view} 没有按值比较（要写成 struct ${view}: View, Equatable 并自己实现 ==）"; fail=1
  fi
  # 只扫这个块自己的 struct（从声明到行首的 }）。放行：调方法（按了做什么）、写入、工程上的常量
  # clock / meters / rebuildStatus（各有自己的订阅规矩）、注释，以及行尾写明「手势里现读」的那几处
  #（手势回调里现读最新值，不在 body 里，不订阅）。盲区：在 body 里**调**工程的方法一样会订阅它读到的属性。
  reads="$(awk -v view="$view" '
    $0 ~ "^(private |fileprivate )?struct " view ": View, Equatable" { inside = 1; next }
    inside && /^\}/ { inside = 0 }
    inside {
      line = $0
      if (line ~ /^[[:space:]]*\/\//) next
      if (line ~ /手势里现读/) next
      sub(/\/\/.*$/, "", line)
      while (match(line, /project\.[A-Za-z_]+/)) {
        name = substr(line, RSTART + 8, RLENGTH - 8)
        rest = substr(line, RSTART + RLENGTH)
        line = rest
        if (name ~ /^(clock|meters|rebuildStatus)$/) continue
        if (rest ~ /^[[:space:]]*[({]/) continue
        if (rest ~ /^[[:space:]]*(=[^=]|\+=|-=)/) continue
        print FILENAME ":" FNR ": project." name
      }
    }' "$file")"
  if [ -n "$reads" ]; then
    echo "✗ ${view} 在块里读了工程的属性（读了就订阅：那个属性一变，全部块都要重算）："
    sed 's/^/    /' <<<"$reads"
    fail=1
  fi
  # 构造处必须紧跟 .equatable()：找到「行首是 视图名(」的那一行，跳过到它同缩进的收尾 )
  #（尾随闭包 `) {` 也算），之后（可以隔着注释、尾随闭包和别的修饰器）必须出现 .equatable()，
  # 别的语句先来了就算没套。
  sites="$(grep -cE "^[[:space:]]*${view}\(" "$host" || true)"
  wrapped="$(awk -v view="$view" '
    $0 ~ "^[[:space:]]*" view "\\(" { indent = match($0, /[^ ]/) - 1; call = 1; closed = 0; next }
    call && !closed { if (match($0, /[^ ]/) - 1 == indent && $0 ~ /^[[:space:]]*\)/) closed = 1; next }
    call && closed {
      if ($0 ~ /^[[:space:]]*\/\//) next
      if ($0 ~ /\.equatable\(\)/) { ok++; call = 0; next }
      if ($0 ~ /^[[:space:]]*\./) next
      # 尾随闭包的内容（更深的缩进）和它同缩进的收尾 } 都还是这一个构造表达式。
      if (match($0, /[^ ]/) - 1 > indent) next
      if (match($0, /[^ ]/) - 1 == indent && $0 ~ /^[[:space:]]*\}/) next
      call = 0
    }
    END { print ok + 0 }' "$host")"
  if [ "$sites" -lt 1 ] || [ "$wrapped" -ne "$sites" ]; then
    echo "✗ ${host} 里 ${view}( 有 ${sites} 处，套了 .equatable() 的只有 ${wrapped} 处：没套的那处每次时间线重算都跟着重算"; fail=1
  fi
done

echo "==> 「预览正在重建」只让那个转圈重算"
# 这个开关放在工程上当 @Published（那时工程是 ObservableObject），每次重建开始 / 结束整个编辑器各重算一轮；改成不发、视图却
# 直接读它，转圈就停在最后一次被别的变化带着画出来的样子（2026-09-25 第一版这么写过：以为没有
# 视图读它）。所以工程上不许有发通知的重建开关，视图只许经 PreviewRebuildSpinner 订阅
# PreviewRebuildStatus（案例 docs/bugfixes/2026-09-25-rebuild-reopens-every-asset.md）。
# 工程换成 @Observable 之后，工程上的存储属性默认就是被观察的（加 @ObservationIgnored 又成了「不发、视图却
# 读」那一种）：两种都不许，开关只许在 PreviewRebuildStatus 上。
if grep -vE '^[[:space:]]*//' Sources/SrtFlow/VideoEditProject.swift | grep -cE '^[[:space:]]*(@[A-Za-z]+ )*(private(\(set\))? )?var isRebuilding' >/dev/null; then
  echo "✗ 工程上又有了重建开关：要么每次重建叫醒读它的视图，要么转圈不刷新 —— 用 PreviewRebuildStatus"; fail=1
fi
need Sources/SrtFlow/VideoEditView.swift 'PreviewRebuildSpinner\(status: project\.rebuildStatus\)' '工具栏上订阅重建开关的转圈'
# 读值的只许是不画界面的两处：工程自己（快路径让路）和性能测试的「落定」。
readers="$(grep -lE 'rebuildStatus\.isRebuilding' $SWIFT_FILES | grep -vE '/(VideoEditProject|PreviewBench)\.swift$' || true)"
if [ -n "$readers" ]; then
  echo "✗ 这些文件直接读了重建开关（不订阅就不刷新，转圈会卡住）：${readers}"; fail=1
fi

echo "==> 时间线本体不许按值跳过根视图那一遍"
# 每点一下时间线重算两遍，看着像能用 .equatable() 省掉第二遍 —— 实测块的选中高亮只在那一遍里更新
#（时间线自己那一遍里 ForEach(rows) 被判成没变），省掉就点了哪段都不亮，读模型的冒烟照样全绿。
# 见 docs/architecture/preview-perf-ratchet.md 第十一节；要改先把块的输入改成那一遍看得见的值。
if grep -cE 'struct VideoEditTimelineView: View, Equatable|extension VideoEditTimelineView: .*Equatable' $SWIFT_FILES >/dev/null; then
  echo "✗ VideoEditTimelineView 成了 Equatable：块的选中高亮会停在上一次（第十一节）"; fail=1
fi
if grep -cE 'VideoEditTimelineView\(project: project, clock: clock\)\.equatable\(\)' Sources/SrtFlow/VideoEditView.swift >/dev/null; then
  echo "✗ 根视图给时间线套了 .equatable()：块的选中高亮会停在上一次（第十一节）"; fail=1
fi

echo "==> 播放器时钟只许跟着播放头动的小视图订阅"
# 时钟（PlayerClock）播放时一秒发二十次，订阅它的视图一秒重算二十遍。2026-09-25 以前根视图、
# 时间线、检查器、素材库那一栏、字幕列表都订阅着它：播放每一跳整个编辑器重算一遍，播放卡
# （docs/bugfixes/2026-09-25-playback-wakes-whole-editor.md）。所以按**类型名单**管：只许是真跟着
# 播放头变、又足够小的那几个。检查器、素材库读 PacedPlayhead（停着的播放头）；按钮能不能点看
# 播放头的用 .disabled(followingPlayhead:)；只关心「换没换句 / 换没换状态」的用 onReceive 自己那一份。
# 要往名单里加，先想清楚它每一跳重算多少东西（docs/architecture/preview-perf-ratchet.md 第十二节）。
ALLOWED_CLOCK_SUBSCRIBERS=" TimelinePlayheadLines TimelinePlayheadHandle PlayheadDisabledModifier \
PreviewPlayerSurface PreviewSubtitleLayer ClipTransformCanvas ShapeOverlayCanvas TextOverlayCanvas \
SubtitlePreviewEditLayer TrackMeterBars BurnInView BurnInPreviewArea SubtitleEditPanel "
# 订阅的写法：@ObservedObject / @StateObject / @EnvironmentObject，类型写在冒号后或直接 = PlayerClock(…)。
# shellcheck disable=SC2086
subscribers="$(awk '
  FNR == 1 { type = "" }
  /^[[:space:]]*(private |fileprivate )?(final )?(struct|class) [A-Za-z0-9_]+/ {
    t = $0
    sub(/^[[:space:]]*(private |fileprivate )?(final )?(struct|class) /, "", t)
    sub(/[^A-Za-z0-9_].*$/, "", t)
    type = t
  }
  /@(ObservedObject|StateObject|EnvironmentObject)[^=]*(: PlayerClock|= PlayerClock\()/ && $0 !~ /^[[:space:]]*\/\// {
    print type "|" FILENAME
  }' $SWIFT_FILES)"
clock_subscribers=0
while IFS='|' read -r type file; do
  [ -n "${type}" ] || continue
  clock_subscribers=$((clock_subscribers + 1))
  case "${ALLOWED_CLOCK_SUBSCRIBERS}" in
    *" ${type} "*) ;;
    *) echo "✗ ${type}（${file}）订阅了播放器时钟：播放时它连同底下的一切一秒重算二十遍"; fail=1 ;;
  esac
done <<<"${subscribers}"
# 扫空（写法全变了）也是绿的 —— 先钉一个下限。
if [ "${clock_subscribers}" -lt 8 ]; then
  echo "✗ 只扫到 ${clock_subscribers} 个订阅时钟的视图，这一节多半扫空了"; fail=1
fi
# 播放中该停着的两处读的是「停着的播放头」，而且各接对了节奏：检查器拖播放头找关键帧要实时
#（whilePaused），素材库拖动中不换小样（atRest，2026-09-25 用户拍板）。
need Sources/SrtFlow/VideoEditInspector.swift '@ObservedObject var playhead: PacedPlayhead' '检查器订阅「停着的播放头」'
need Sources/SrtFlow/VideoEditView.swift 'playhead: clock\.whilePaused' '检查器接的是 whilePaused'
need Sources/SrtFlow/VideoEditTransitionLibrary.swift '@ObservedObject var playhead: PacedPlayhead' '转场库订阅「停稳了的播放头」'
need Sources/SrtFlow/VideoEditFilterLibrary.swift '@ObservedObject var playhead: PacedPlayhead' '滤镜库订阅「停稳了的播放头」'
# 两页都接 atRest，一处都不许是 whilePaused（只查「出现过」的话，一页接错了另一页会把它顶成绿的）。
rest_panels="$(grep -cE '(Transition|Filter)LibraryPanel\(project: project, playhead: project\.clock\.atRest\)' \
  Sources/SrtFlow/VideoEditLibraryColumn.swift || true)"
if [ "${rest_panels}" -ne 2 ] || grep -cE 'whilePaused' Sources/SrtFlow/VideoEditLibraryColumn.swift >/dev/null; then
  echo "✗ 素材库那一栏的转场 / 滤镜两页必须都接 clock.atRest（拖播放头的过程中不换小样）"; fail=1
fi
# 慢读法只认「放置」：订阅了时钟的时间回调，播放把它带着走的每一跳都会叫醒检查器和素材库。
if grep -cE 'clock\.\$time' Sources/SrtFlow/PacedPlayhead.swift >/dev/null; then
  echo "✗ PacedPlayhead 订阅了 clock.\$time —— 播放的每一跳都会叫醒检查器和素材库"; fail=1
fi

if [ "${fail}" -eq 0 ]; then
  echo "✓ 预览性能计数全部接上"
  echo "All checks passed"
else
  echo
  echo "漏插的计数一条命令补上：checks/preview-perf-wiring.sh --fix"
  echo "（只补标准写法；body 写成一行、Canvas 开头跨行的，先改成标准写法。）"
  echo "规矩见 docs/architecture/preview-perf-ratchet.md「计数必须接满」。"
  exit 1
fi
