#!/usr/bin/env bash
# checks/timeline-drag-wiring.sh 的一节：剪辑页上记住的开关（磁吸 / 吸附 / 联动 / 播放跟随 + 字幕列表的跟随）
# 和播放跟随的接线。
#
# **不单独跑**：由 timeline-drag-wiring.sh 用 `source` 装进来，共用它的 fail / grep_code / require_func
# 和路径变量（PROJECT、PLAYHEAD、VIEW …）。默认值和记忆的纯值规则由 scripts/check-timeline-zoom.sh 第 4 节钉；
# 这里钉「接没接对」。长期约束见 docs/architecture/editor-remembered-toggles.md。
#
# 默认值是产品口径（2026-09-18：吸附开、磁吸关；2026-10-01：播放跟随、字幕列表跟随默认关，四个工具栏开关一起记住；
# 2026-10-02：联动默认开）：
# 顺手「改回 true」会静默改掉整个剪辑手感，所以字面量钉在 EditorToggles 里、这里再对一遍。

TOGGLES="Sources/SrtFlow/EditorToggles.swift"
TOOLBAR_ICONS="Sources/SrtFlow/VideoEditToolbarIcons.swift"
SUBTITLE_PANEL="Sources/SrtFlow/VideoEditSubtitlePanel.swift"
SMOKE_CHANGES="Sources/SrtFlow/SmokeProjectChanges.swift"
FOLLOW_MATH="Sources/SrtFlow/VideoEditTimelinePlayheadFollow.swift"
for f in "$TOGGLES" "$TOOLBAR_ICONS" "$SUBTITLE_PANEL" "$SMOKE_CHANGES" "$FOLLOW_MATH"; do
  [ -f "$f" ] || fail "找不到 ${f}：记住的开关 / 播放跟随的代码挪走了，这一节会扫个空"
done

# ── 11a. 默认值只有 EditorToggles 一份，字面量就是产品口径 ─────────────────
grep_code '^            case \.magnet: false' "$TOGGLES" \
  || fail "磁吸的默认值不是关：用户的剪法要留间隙，默认合拢会把间隙吃掉"
grep_code '^            case \.snapping: true' "$TOGGLES" \
  || fail "吸附的默认值不是开：它不改任何自动行为"
grep_code '^            case \.linkage: true' "$TOGGLES" \
  || fail "联动的默认值不是开（2026-10-02 拍板，同剪映）：关着剪掉一段之后后面的字幕、音效全错位"
grep_code '^            case \.followPlayhead: false' "$TOGGLES" \
  || fail "播放跟随的默认值不是关：用户拍板播放时轨道区域停在哪就停在哪"
grep_code '^            case \.subtitleListFollows: false' "$TOGGLES" \
  || fail "字幕列表跟随的默认值不是关（2026-10-01 拍板）"
# 工程上那三个只许从 EditorToggles 读初值，不许再写字面量（磁吸跟着工程走，见 11f）。
for pair in 'snappingEnabled|snapping' 'linkageEnabled|linkage' 'timelineFollowsPlayhead|followPlayhead'; do
  IFS='|' read -r prop key <<<"$pair"
  grep_code "^    var ${prop} = EditorToggles.read(.${key})" "$PROJECT" \
    || fail "工程上的 ${prop} 没从 EditorToggles.read(.${key}) 读初值（默认值只许有一份）"
  grep_code "EditorToggles.write(.${key}, ${prop})" "$PROJECT" \
    || fail "工程上的 ${prop} 拨了没记下来（didSet 里要 EditorToggles.write(.${key}, …)）"
done
# 这几个键只许 EditorToggles 认识：别处直接拿字符串去 UserDefaults / @AppStorage 读，就绕开了
# 「脚本驱动时永远默认值」（冒烟的属性清单里同名的字符串是属性名，不算）。
KEYS='(magnetEnabled|snappingEnabled|linkageEnabled|timelineFollowsPlayhead|subtitleListFollowsPlayback)'
OTHERS="$(grep -rlnE "forKey: \"${KEYS}\"|AppStorage\\(\"${KEYS}\"" Sources/SrtFlow --include='*.swift' || true)"
[ -z "$OTHERS" ] || fail "开关的 UserDefaults 键在 EditorToggles 之外被直接读写了：${OTHERS}"

# ── 11b. 脚本驱动（性能测试 / 冒烟）时起手永远是默认值、写不落盘 ─────────────
grep_code 'static var store: UserDefaults? { store(scripted: PerfCounters.isEnabled) }' "$TOGGLES" \
  || fail "EditorToggles.store 没按 PerfCounters.isEnabled 分开：冒烟 / 性能场景会把这台机器上次拨的开关带进来"
grep_code 'scripted ? nil : .standard' "$TOGGLES" \
  || fail "脚本驱动时 store 不是 nil（读要给默认值、写要丢掉）"
grep_code '("timelineFollowsPlayhead", \\.timelineFollowsPlayhead)' "$SMOKE_CHANGES" \
  || fail "冒烟的属性清单没登记 timelineFollowsPlayhead（冒烟起手对 Mirror 时会直接报错）"

# ── 11c. 工具栏四个开关在自己的小视图里拨（拨一个不叫醒整个编辑器） ─────────
grep_code 'TimelineToolbarToggles(project: project)' "$EDITOR_ROOT" \
  || fail "工具栏没摆出 TimelineToolbarToggles（四个开关的小视图）"
grep_code '\$project\.' "$EDITOR_ROOT" \
  && fail "编辑器根视图又直接绑 \$project.x 了：开关要在 TimelineToolbarToggles 里拨"
for key in snappingEnabled linkageEnabled timelineFollowsPlayhead; do
  grep_code "isOn: \$project.${key}" "$TOOLBAR_ICONS" \
    || fail "TimelineToolbarToggles 里少了 ${key} 的开关"
done
grep_code 'isOn: Binding(get: { project.magnetEnabled }, set: { project.setMagnet($0) })' "$TOOLBAR_ICONS" \
  || fail "工具栏的磁吸开关没走 setMagnet（磁吸跟着工程走，拨它要改 state.mainMagnet、进撤销栈）"

# ── 11d. 播放跟随：开关传进播放头竖线、推不推只问 PlayheadFollow、只碰横向 ─────
grep_code 'follows: project.timelineFollowsPlayhead' "$VIEW" \
  || fail "时间线没把播放跟随的开关传给 TimelinePlayheadLines（follows:）"
if BODY="$(require_func 'private func followPlayhead(' "$PLAYHEAD")"; then
  grep -q 'PlayheadFollow.scrollTarget(' <<<"$BODY" \
    || fail "followPlayhead 没走 PlayheadFollow.scrollTarget（推不推、推到哪只有那一份算法）"
  grep -q 'enabled: follows' <<<"$BODY" \
    || fail "followPlayhead 没把开关交给 PlayheadFollow（关着时必须一下都不推）"
  grep -q 'scrollHorizontally(to: target, animated: true)' <<<"$BODY" \
    || fail "followPlayhead 推的不是算出来的 target，或者不再只碰横向"
  grep -q 'scrollVertically\|offsetY' <<<"$BODY" \
    && fail "followPlayhead 碰了纵向：正在看下面几条轨时一按播放，画面会被拽回顶上"
fi
PUSHES="$(grep -c 'scrollHorizontally(to:' "$PLAYHEAD" || true)"
[ "$PUSHES" -eq 2 ] \
  || fail "播放头竖线里推横向滚动的地方有 ${PUSHES} 处，应当正好 2 处（播放跟随 + Return 回到开头）"
grep_code 'onReceive(clock.wentToStart) { geometry.scrollHorizontally(to: 0, animated: true) }' "$PLAYHEAD" \
  || fail "Return / Home 回到开头不再滚回最左了（用户拍板保留，开关不管它）"

# ── 11e. 剪辑页字幕列表的跟随：默认关、记住；烧录页的那个不归这里管 ─────────
grep_code 'followsPlayback = EditorToggles.read(.subtitleListFollows)' "$SUBTITLE_PANEL" \
  || fail "字幕列表的跟随按钮没从 EditorToggles 读初值（默认关、记住）"
grep_code 'EditorToggles.write(.subtitleListFollows, follows)' "$SUBTITLE_PANEL" \
  || fail "字幕列表的跟随按钮拨了没记下来"
grep_code 'guard followsPlayback, clock.isPlaying' "$SUBTITLE_PANEL" \
  || fail "字幕列表播放时滚到正在说的那句不再看跟随按钮了"

# ── 11f. 磁吸跟着工程走（2026-10-02 用户拍板，同剪映每个草稿各记各的）─────────────
# 开没开是 `state.mainMagnet`（进撤销栈、存进工程文件，老工程缺键 = 关）；工程上的 magnetEnabled 只是镜子；
# 拨它只走 setMagnet（顺带记成新建工程的默认）；perform / liveApply 收尾只经 MainMagnet.settle（改到 V1 的排布才排）。
# 南极工程：磁吸全 App 一份、每次 perform 都排，改一条音量曲线整条 V1 合拢（docs/bugfixes/2026-10-02-magnet-closes-v1-gaps-on-any-edit.md）。
MAGNET="Sources/SrtFlow/VideoEditMainMagnet.swift"
DOCUMENT="Sources/SrtFlow/VideoEditProjectDocument.swift"
for f in "$MAGNET" "$DOCUMENT"; do
  [ -f "$f" ] || fail "找不到 ${f}：磁吸的代码挪走了，这一节会扫个空"
done
grep_code '^    private(set) var magnetEnabled = EditorToggles.read(.magnet)$' "$PROJECT" \
  || fail "工程上的 magnetEnabled 不再是只读的镜子（谁都能直接写，就绕开了 state.mainMagnet 和撤销栈）"
grep_code 'if magnetEnabled != state.mainMagnet { magnetEnabled = state.mainMagnet }' "$PROJECT" \
  || fail "state 变了没把磁吸的镜子对上（撤销 / 打开工程之后工具栏显示的不是这个工程的磁吸）"
if BODY="$(require_func 'func setMagnet(' "$PROJECT")"; then
  grep -q 'EditorToggles.write(.magnet, on)' <<<"$BODY" || fail "setMagnet 没把拨的值记成新建工程的默认"
  grep -q 'perform(rebuildsPreview: on) { $0.mainMagnet = on }' <<<"$BODY" \
    || fail "setMagnet 没走 perform 改 state.mainMagnet（拨磁吸要一步撤销、拨开时 perform 收尾把 V1 排紧）"
fi
for entry in 'func perform(' 'func liveApply('; do
  if BODY="$(require_func "$entry" "$PROJECT")"; then
    grep -q 'MainMagnet.settle(&next, after:' <<<"$BODY" || fail "${entry} 收尾没经 MainMagnet.settle（改字幕 / 音量也会把 V1 合拢）"
    if grep -q 'packMain()' <<<"$BODY"; then fail "${entry} 里又直接 packMain 了：要不要排只许 MainMagnet 判"; fi
  fi
done
grep_code 'replaceStateForDocument(MainMagnet.newTimeline(remembered: EditorToggles.read(.magnet)))' "$DOCUMENT" \
  || fail "新建工程没走 MainMagnet.newTimeline（磁吸不跟上次拨的值）"
grep_code 'private(set) var state = MainMagnet.newTimeline(remembered: EditorToggles.read(.magnet))' "$PROJECT" \
  || fail "启动时那个空工程没走 MainMagnet.newTimeline"
# 写 mainMagnet 的只许这几处：setMagnet、newTimeline、读盘、录屏导入时读（别处改了它就绕开了撤销栈和镜子）。
WRITES="$(grep -rn 'mainMagnet = ' Sources/SrtFlow --include='*.swift' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' \
  | grep -vE "VideoEditProject.swift:.*(\\\$0\.mainMagnet = on|magnetEnabled = state\.mainMagnet)|VideoEditMainMagnet.swift:.*timeline\.mainMagnet = remembered|VideoEditModels.swift:.*(var mainMagnet = false|mainMagnet = try c\.decodeIfPresent)" || true)"
[ -z "$WRITES" ] || fail "mainMagnet 在 setMagnet / newTimeline / 读盘之外被写了：${WRITES}"
grep_code 'object\["magnet"\] = .bool(project.magnetEnabled)' "Sources/SrtFlow/AITimelineTools.swift" \
  || fail "get_timeline 没报这个工程的磁吸（AI 不知道往 V1 放的起点会被排紧）"
[ "$(grep -l 'AILinkageReport.magnet(' Sources/SrtFlow/*.swift | wc -l | tr -d ' ')" -ge 4 ] \
  || fail "AI 改工程的工具结果里没报磁吸排了 V1（add_clips / edit_clip / delete_items / cut_speech / cut_to_beat）"

