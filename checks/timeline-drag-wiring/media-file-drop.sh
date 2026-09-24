#!/usr/bin/env bash
# checks/timeline-drag-wiring.sh 的一节：从 Finder 拖文件进轨道 / ⌘V 粘贴进轨道的接线。
#
# **不单独跑**：由 timeline-drag-wiring.sh 用 `source` 装进来，共用它的 fail / grep_code /
# require_func / extract_func 和各文件路径变量（TIMELINE_VIEWS、DROP_ROUTER、DRAG …）。
# 拆出来是因为主文件超过了单文件上限、只许降不许涨（docs/architecture/coding-standards.md）。

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
if PLAN_BODY="$(awk '/private func plan\(at location: CGPoint, open: TimelineSeam\?\) -> MediaFileDropPlan\?/,/^    \}/' "$FILE_DROP")"; then
  [ -n "$PLAN_BODY" ] || fail "找不到文件落点的 plan(at:open:)（在 ${FILE_DROP}）：接线守卫失去目标 —— 改名了就同步改这里"
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
if AUDIO_PLAN="$(require_func 'private func plan(at location: CGPoint, open: TimelineSeam?) -> AudioLibraryDropPlan?' Sources/SrtFlow/AudioLibraryDrag.swift)"; then
  grep -q 'duration / 2' <<<"$AUDIO_PLAN" \
    && fail "音频库落点又按中点对齐了：整首音乐的起点会退回一分多钟，拖到哪都落不到指针那儿"
fi

# 5) 落地不许回读那份 @State：@Binding 的写入不是同步可见的，回读会让落点晚
#    一帧（同转场第 5 条）。落点只许从**这一拍的** info.location 算。
if DROP_BODY="$(awk '/func performDrop\(info: DropInfo\)/,/^    \}/' "$FILE_DROP")"; then
  grep -q 'info.location.x / pps' <<<"$DROP_BODY" \
    || fail "文件落点的 performDrop 没按这一拍的指针算时间：读 preview 会和画框那一拍脱节"
  grep -q 'trackTarget(at: info.location, open: seamAim(at: info.location).open)' <<<"$DROP_BODY" \
    || fail "文件落点的 performDrop 没按这一拍的指针（和此刻拉开的缝）算目标轨"
  grep -q 'defer { finish(animated: false) }' <<<"$DROP_BODY" \
    || fail "文件落点的 performDrop 没收尾（finish）：暂存留着，心跳也可能空转，缝也不合上"
fi
if EXIT_BODY="$(awk '/func dropExited\(info: DropInfo\)/,/^    \}/' "$FILE_DROP")"; then
  grep -q 'finish(animated: true)' <<<"$EXIT_BODY" \
    || fail "文件落点的 dropExited 没收尾（finish）：指针离开后框还挂着，缝也不合上"
fi
if FINISH_BODY="$(awk '/private func finish\(animated: Bool\)/,/^    \}/' "$FILE_DROP")"; then
  [ -n "$FINISH_BODY" ] || fail "找不到文件落点的 finish(animated:)：接线守卫失去目标"
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
# 8b) 落点框的**外观只有一份账**：新轨那种「行还不存在」的缩略框必须用同一套几何，
#     各写一份字面量会分叉。2026-09-24 起跨轨拖动的新轨都落在拉开的缝里（几何在
#     `TimelineSeams.ghostY`），`newLaneY` 只剩拖文件进来的两处：梯子「撞上就抬到最上面
#     新开一条」和「音频都放不下、最下面新开一条」—— 那两种没有缝可开。
#     数调用点，别数「某个文件里有没有」（那种写法抓不到偷偷写回的）。
NEW_LANE_CALLS="$(grep -rh 'newLaneY(' Sources/SrtFlow --include='*.swift' \
  | grep -vE '^[[:space:]]*(//|\*)' | grep -v 'static func newLaneY' | wc -l | tr -d ' ')"
[ "$NEW_LANE_CALLS" -eq 2 ] \
  || fail "newLaneY 的调用点有 ${NEW_LANE_CALLS} 处（应为 2：拖文件进来开新轨的上/下）—— 少一处就是有人写回了字面量，多一处就是跨轨拖动绕开了缝的几何"
GHOST_CALLS="$(grep -rh 'TimelineSeams.ghostY(' Sources/SrtFlow --include='*.swift' \
  | grep -vE '^[[:space:]]*(//|\*)' | wc -l | tr -d ' ')"
[ "$GHOST_CALLS" -ge 1 ] \
  || fail "没有一处按 TimelineSeams.ghostY 画缝里的缩略框：框和缝会各画各的"

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
