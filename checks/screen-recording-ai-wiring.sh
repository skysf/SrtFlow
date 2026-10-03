#!/usr/bin/env bash
# 扫描守卫：AI 录屏（record_screen，2026-10-03）的接线。
#
# 协调者、路由、AI 会话都是 @MainActor 的 App 类型，自检编不动；产品口径（docs/plans/2026-10-03-screen-recording-mcp.md）
# 里用户点名的几条只能在源码层面钉住 —— 漏一条就是 AI 录屏时弹了窗、盖住要录的画面、覆盖了文件，或者撤一步全退。
# 写法同 fal-wiring.sh：文件找不到直接红（扫空 = 假绿）。
#
# 钉的事：
#   1. AI 起的录制**从不打开系统的选择窗口**（用户：「授权了以后，日后就不要再自己弹了」）：chooseSource 头一行先认 AI 挑好的
#      preset；建 picker 之前 `guard session.asksTheUser`；picker 只在那一处建；AI 的文件里不出现 ScreenRecordingSourcePicker /
#      SCContentSharingPicker；AI 开录总把挑好的来源交进去。
#   2. 设置页、残缺框只给手动的会话：设置页的显隐是 showsSetupSheet（含 asksTheUser）、残缺结果 `if recording.isPartial, session.asksTheUser`；
#      AI 叫用户拖区域时不激活 App（激活会把 SrtFlow 的窗口拎到最前面、盖住要录的地方）。
#   3. **从不覆盖**：AI 的会话 replacesExistingOutput = false；提交时撞上已有文件先避让、落进 manifest，之后才轮到 replaceItemAt，
#      replaceItemAt 只在 ScreenRecordingFileCommit 一处。
#   4. 手动记住的偏好 AI 不写：lastDirectory 只在 `if session.asksTheUser` 里写；AI 的文件不写 ScreenRecordingPreferences。
#   5. **入轨那一下包一步撤销**（异步落账，docs/architecture/ai-control-mcp.md 第四节第 1 条）：AI 的 landing 是
#      `AIUndoGrouping.step(project.effectiveUndoManager, body)`，开录、接手手动的录制、处置残留都用它；两条入轨的 perform 都在
#      `landing.commit` 里，文件里没有别的 perform。
#   6. **录制中 AI 别的改动不把 SrtFlow 摆到前面**（会被录进去）：路由按 `ScreenRecordingCoordinator.shared.isBusy` 跳过；
#      record_screen 自己不摆剪辑页。
#   7. **丢弃先问、进废纸篓**：AIScreenRecordingLeftovers 里先 `AIFileTools.confirmTrash(` 再 `trashItem(`；AI 的文件里没有 removeItem。
#   8. **授权一次运行只请求一次**：requestScreenAccess 在 AI 的文件里只出现一次，前面是 `guard !requestedPermission` 和置位。
#   9. AI 起的浮窗放主屏左下角（顶部正中压在浏览器的地址栏上，AI 截屏又看不见浮窗）。
#  10. 录屏中的锁换成 AI 能照做的话：set_canvas 改帧率先挡、一样都不改（以前静默不改还回成功，
#      docs/bugfixes/2026-10-03-set-canvas-fps-ignored-while-recording.md）；换工程（open_project / new_project）先挡；
#      **按状态说**：在等决定时说 resolve、不说 stop（那时没在录，2026-10-03 真机首测撞上的）。
#  11–13. 真机首测修的另外三处（docs/bugfixes/2026-10-03-record-screen-first-device-test.md）：按时长停要扣掉切到「录制中」之前已经录下的那一截；
#      没授权时不列窗口（系统只把自己的窗口算作能录，列出来会误导）；残留报保存之后的文件名，不报隐藏的 .partial 临时文件。
#
# 用法：checks/screen-recording-ai-wiring.sh
set -euo pipefail
cd "$(dirname "$0")/.."

SETUP="Sources/SrtFlow/ScreenRecordingCoordinator+Setup.swift"
COORDINATOR="Sources/SrtFlow/ScreenRecordingCoordinator.swift"
SESSION="Sources/SrtFlow/ScreenRecordingSession.swift"
COMMIT="Sources/SrtFlow/ScreenRecordingFileCommit.swift"
PANEL="Sources/SrtFlow/ScreenRecordingControlPanel.swift"
IMPORT="Sources/SrtFlow/VideoEditProject+ScreenRecording.swift"
VIEW="Sources/SrtFlow/VideoEditView.swift"
ROUTER="Sources/SrtFlow/AIToolRouter.swift"
TOOL="Sources/SrtFlow/AIScreenRecordingTool.swift"
LEFTOVERS="Sources/SrtFlow/AIScreenRecordingLeftovers.swift"
JOB="Sources/SrtFlow/AIScreenRecordingJob.swift"
SOURCES="Sources/SrtFlow/AIScreenSources.swift"
REQUEST="Sources/SrtFlow/AIScreenRecordingRequest.swift"
MATCH="Sources/SrtFlow/AIScreenSourceMatch.swift"
OVERLAY="Sources/SrtFlow/AIOverlayTools.swift"
PROJECT_TOOLS="Sources/SrtFlow/AIProjectTools.swift"
for file in "${SETUP}" "${COORDINATOR}" "${SESSION}" "${COMMIT}" "${PANEL}" "${IMPORT}" "${VIEW}" "${ROUTER}" "${TOOL}" "${LEFTOVERS}" \
            "${JOB}" "${SOURCES}" "${REQUEST}" "${MATCH}" "${OVERLAY}" "${PROJECT_TOOLS}"; do
  if [ ! -f "${file}" ]; then
    echo "✗ 找不到 ${file} —— 改名了就同步改这里（扫空 = 假绿）" >&2
    exit 1
  fi
done
AI_FILES=("${TOOL}" "${LEFTOVERS}" "${JOB}" "${SOURCES}" "${REQUEST}" "${MATCH}")

FAILED=0
fail() { echo "✗ $1" >&2; FAILED=1; }
count() { grep -c -- "$1" "$2" || true; }
line_of() { { grep -n -- "$1" "$2" || true; } | head -1 | cut -d: -f1; }
# 第一个参数的行在第二个之前（都找得到）。
before() { [ -n "$1" ] && [ -n "$2" ] && [ "$1" -lt "$2" ]; }

# 1. AI 起的录制从不打开系统的选择窗口。
before "$(line_of 'if let preset = options.preset { return (preset.source, preset.filter) }' "${SETUP}")" \
       "$(line_of 'switch options.sourceKind {' "${SETUP}")" \
  || fail "${SETUP}：chooseSource 要先认 AI 挑好的来源（preset），再按种类开选择窗口 / 区域框"
before "$(line_of 'guard session.asksTheUser else { throw ScreenRecordingError.sourceUnavailable }' "${SETUP}")" \
       "$(line_of 'let picker = ScreenRecordingSourcePicker()' "${SETUP}")" \
  || fail "${SETUP}：建系统选择窗口（ScreenRecordingSourcePicker）之前要先挡住 AI 起的会话（用户：授权以后不要再弹）"
[ "$(count 'ScreenRecordingSourcePicker()' "${SETUP}")" -eq 1 ] || fail "${SETUP}：系统选择窗口只许在 chooseSource 那一处建"
if grep -nE 'ScreenRecordingSourcePicker|SCContentSharingPicker' "${AI_FILES[@]}"; then
  fail "AI 录屏的文件里出现了系统选择窗口：AI 自己挑来源、从不开它"
fi
grep -q 'options.preset = picked.preset' "${TOOL}" || fail "${TOOL}：开录没把 AI 挑好的来源交给协调者（会落到系统选择窗口那一支）"

# 2. 设置页、残缺框只给手动的会话；AI 叫用户拖区域时不激活 App。
grep -q 'var asksTheUser: Bool { driver == .user }' "${SESSION}" || fail "${SESSION}：asksTheUser 应当只对手动的会话为真"
grep -q 'var showsSetupSheet: Bool { state == .configuring && session.asksTheUser }' "${COORDINATOR}" \
  || fail "${COORDINATOR}：设置页的显隐要排除 AI 起的会话（它也路过 .configuring）"
grep -q 'get: { recordingCoordinator.showsSetupSheet }' "${VIEW}" || fail "${VIEW}：设置页没按 showsSetupSheet 显示（AI 开录会弹出设置页）"
grep -q 'if recording.isPartial, session.asksTheUser {' "${COORDINATOR}" \
  || fail "${COORDINATOR}：残缺结果的处置框只给手动的会话（AI 点不着，工程会一直锁着）"
[ "$(count 'pendingPartial = recording' "${COORDINATOR}")" -eq 1 ] || fail "${COORDINATOR}：残缺框只许在那一处端出来"
grep -q 'panel.present(activatingApp: session.asksTheUser)' "${SETUP}" \
  || fail "${SETUP}：AI 叫用户拖区域时不许激活 App（会把 SrtFlow 的窗口拎到最前面、盖住要录的地方）"

# 3. 从不覆盖。
grep -q 'plan.replacesExistingOutput = false' "${TOOL}" || fail "${TOOL}：AI 起的会话必须 replacesExistingOutput = false（从不覆盖）"
grep -q 'replacesExistingOutput: session.replacesExistingOutput' "${COORDINATOR}" || fail "${COORDINATOR}：提交没按会话决定能不能替换"
RETARGET_AT="$(line_of 'if !replacesExistingOutput, manager.fileExists(atPath: mainURL.path) {' "${COMMIT}")"
PERSIST_AT="$(line_of 'try persist(.committingMain)' "${COMMIT}")"
REPLACE_AT="$(line_of 'replaceItemAt(' "${COMMIT}")"
if ! before "${RETARGET_AT}" "${PERSIST_AT}" || ! before "${PERSIST_AT}" "${REPLACE_AT}"; then
  fail "${COMMIT}：不许替换时要先避让、把新目标落进 manifest（committingMain），之后才轮到 replaceItemAt"
fi
others="$(grep -ln 'replaceItemAt(' Sources/SrtFlow/ScreenRecording*.swift Sources/SrtFlow/AIScreen*.swift | grep -v "^${COMMIT}\$" || true)"
[ -z "${others}" ] || fail "这些文件也在替换文件：$(tr '\n' ' ' <<<"${others}")—— 替换只许在 ScreenRecordingFileCommit（手动的、用户确认过的那一次）"

# 4. 手动记住的偏好 AI 不写。
grep -q 'if session.asksTheUser { ScreenRecordingPreferences.lastDirectory = ' "${COORDINATOR}" \
  || fail "${COORDINATOR}：记住目录只许给手动的会话（AI 给的位置只用于这一次）"
[ "$(count 'ScreenRecordingPreferences.lastDirectory = ' "${COORDINATOR}")" -eq 1 ] || fail "${COORDINATOR}：记住目录只许在那一处"
if grep -nE 'ScreenRecordingPreferences\.[A-Za-z]+ *= ' "${AI_FILES[@]}"; then
  fail "AI 录屏的文件写了手动记住的偏好（麦克风、目录）：AI 的设置只用于这一次"
fi

# 5. 入轨那一下包一步撤销。
[ "$(count 'commit: { body in AIUndoGrouping.step(project.effectiveUndoManager, body) }' "${TOOL}")" -eq 1 ] \
  || fail "${TOOL}：AI 的 landing 必须把入轨那一次 perform 包进 AIUndoGrouping.step（异步落账，不包就撤一步全退）"
grep -q 'plan.landing = landing(for: project)' "${TOOL}" || fail "${TOOL}：开录的会话没带上 AI 的 landing"
[ "$(count 'coordinator.handOver(to: job, landing: landing(for: project))' "${TOOL}")" -eq 1 ] \
  || fail "${TOOL}：AI 去停一段手动的录制时，入轨那一下也要包 AI 的一步撤销"
[ "$(count 'coordinator.handOver(to: job, landing: AIScreenRecordingTool.landing(for: project))' "${LEFTOVERS}")" -eq 1 ] \
  || fail "${LEFTOVERS}：AI 把手动录制的残缺结果加进时间线，要包 AI 的一步撤销"
grep -q 'resolveRecovery(.addToTimeline, landing: AIScreenRecordingTool.landing(for: project))' "${LEFTOVERS}" \
  || fail "${LEFTOVERS}：AI 把崩溃留下的录制加进时间线，要包 AI 的一步撤销"
[ "$(count 'landing.commit { perform {' "${IMPORT}")" -eq 2 ] && [ "$(count 'perform {' "${IMPORT}")" -eq 2 ] \
  || fail "${IMPORT}：两条入轨（刚录完的、崩溃恢复的）的 perform 都要经 landing.commit，文件里不许有别的 perform"
grep -q 'importScreenRecording(result, request: request, landing: session.landing)' "${COORDINATOR}" \
  || fail "${COORDINATOR}：入轨没把会话的 landing 传下去"

# 6. 录制中 AI 别的改动不把 SrtFlow 摆到前面；record_screen 自己不摆剪辑页。
grep -q 'let recordingScreen = ScreenRecordingCoordinator.shared.isBusy' "${ROUTER}" \
  && grep -q 'bringForward: startsNewRound && visible && !recordingScreen' "${ROUTER}" \
  || fail "${ROUTER}：录屏进行中还会把 SrtFlow 摆到前面（会盖住正在录的画面、被录进去）"
POLICY="$(grep -A1 'case .recordScreen:$' "${ROUTER}" | tail -1)"
grep -q '(serialized, presentsEditor, startsRound) = (true, false, true)' <<<"${POLICY}" \
  || fail "${ROUTER}：record_screen 要排队、不摆剪辑页、算这一轮（现在是：${POLICY}）"

# 7. 丢弃先问、进废纸篓。
before "$(line_of 'AIFileTools.confirmTrash(' "${LEFTOVERS}")" "$(line_of 'trashItem(' "${LEFTOVERS}")" \
  || fail "${LEFTOVERS}：丢弃上次没收完的录制要先问（AIFileTools.confirmTrash）、再进废纸篓"
if grep -n 'removeItem(' "${AI_FILES[@]}"; then
  fail "AI 录屏的文件直接删了文件：AI 删东西一律先问、进废纸篓"
fi

# 8. 授权一次运行只请求一次。
REQUESTS="$(cat "${AI_FILES[@]}" | grep -c 'requestScreenAccess()' || true)"
[ "${REQUESTS}" -eq 1 ] || fail "AI 录屏的文件里请求屏幕录制授权的地方应恰好一处（现在 ${REQUESTS} 处）"
GUARD_AT="$(line_of 'guard !requestedPermission else {' "${TOOL}")"
SET_AT="$(line_of 'requestedPermission = true' "${TOOL}")"
ASK_AT="$(line_of 'requestScreenAccess()' "${TOOL}")"
if ! before "${GUARD_AT}" "${SET_AT}" || ! before "${SET_AT}" "${ASK_AT}"; then
  fail "${TOOL}：没授权时一次运行只许弹一次（先 guard !requestedPermission、置位，再请求）"
fi

# 9. AI 起的浮窗在左下角。
grep -q 'plan.panelPlacement = .bottomLeft' "${TOOL}" && grep -q 'case .bottomLeft:' "${PANEL}" \
  || fail "${TOOL} / ${PANEL}：AI 起的录制浮窗要放主屏左下角（顶部正中压着浏览器的地址栏，AI 截屏看不见浮窗）"

# 10. 录屏中的锁换成 AI 能照做的话。
LOCK_AT="$(line_of 'ScreenRecordingCoordinator.shared.isBusy {' "${OVERLAY}")"
if ! before "${LOCK_AT}" "$(line_of 'project.setCanvasRatio(ratio)' "${OVERLAY}")" \
   || ! before "${LOCK_AT}" "$(line_of 'project.setFrameRate(rate)' "${OVERLAY}")"; then
  fail "${OVERLAY}：录屏中 set_canvas 改帧率要先报错、一样都不改（setFrameRate 那道闸只亮提示，AI 会以为改了）"
fi
SWITCH_AT="$(line_of 'throw AIToolError(AIScreenRecordingTool.lockMessage("the project cannot be switched now"))' "${PROJECT_TOOLS}")"
if ! before "${SWITCH_AT}" "$(line_of 'guard project.isUntitled, !project.state.isEmpty else { return nil }' "${PROJECT_TOOLS}")"; then
  fail "${PROJECT_TOOLS}：录屏中换工程要先挡、告诉 AI 用 record_screen action=stop（界面那句「先停止录屏」AI 照做不了）"
fi

grep -q 'throw AIToolError(AIScreenRecordingTool.lockMessage("the frame rate cannot be changed now"))' "${OVERLAY}" \
  || fail "${OVERLAY}：录屏中改帧率的报错要经 AIScreenRecordingTool.lockMessage（按状态说 stop 还是 resolve）"
LOCK_BODY="$(awk '/static func lockMessage\(/,/^    \}/' "${TOOL}")"
grep -q 'if case .partialRecovery = coordinator.state {' <<<"${LOCK_BODY}" && grep -q 'AIScreenRecordingLeftovers.waiting(coordinator)' <<<"${LOCK_BODY}" \
  || fail "${TOOL}：lockMessage 在等决定时要说 resolve（AIScreenRecordingLeftovers.waiting），不是叫 AI 去 stop —— 那时根本没在录"

# 11. 按时长停要扣掉已经录下的那一截。
grep -q 'recordingStarted(session: request.sessionID, alreadyRecorded: writer?.elapsed ?? 0)' "${COORDINATOR}" \
  || fail "${COORDINATOR}：告诉观察者「开录了」时要带上文件里已经有几秒（画面在 startCapture 返回前就开始写了）"
grep -q 'let remaining = max(0, duration - alreadyRecorded)' "${JOB}" && grep -q 'Task.sleep(nanoseconds: UInt64(remaining \* 1_000_000_000))' "${JOB}" \
  || fail "${JOB}：duration 要只等剩下的那一截（扣掉 alreadyRecorded），不然成片长出半秒到一秒多"

# 12. 没授权时不列窗口。
before "$(line_of 'if ScreenRecordingPermissions.screen == .authorized {' "${SOURCES}")" "$(line_of 'AIScreenSourceMatch.recordable(windows())' "${SOURCES}")" \
  || fail "${SOURCES}：没授权时系统只给 SrtFlow 自己的窗口，不许列出来（会让 AI 以为只有它）"

# 13. 残留报保存之后的文件名。
grep -q 'file = plannedFile(pending)' "${LEFTOVERS}" && grep -q 'object\["file"\] = .string(AIWorkspace.shared.display(file))' "${LEFTOVERS}" \
  || fail "${LEFTOVERS}：残留要报保存之后叫什么（plannedFile），不报隐藏的 .partial 临时文件名"

if [ "${FAILED}" -ne 0 ]; then
  echo "AI 录屏接线守卫失败" >&2
  exit 1
fi
echo "✓ AI 录屏接线守卫通过"
