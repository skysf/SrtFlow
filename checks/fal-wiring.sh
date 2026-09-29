#!/usr/bin/env bash
# 扫描守卫：fal.ai 生成（方案第 6 块）在 App 里的接线。
#
# 自检编不动 App 里那些 @MainActor 的类型（AISession、AIJobs、路由……），「花钱先问、问的时候不弹模态框、Key 只经一处读、
# 没做出来的钱要退回、清单里有没有这个工具跟着 Key 走」只能在源码层面钉住。每一条都是花用户的钱的地方 ——
# 漏一条就是没问就花、或者问不到人、或者 Key 被读来读去。写法同 encode-settings-memory.sh：文件找不到直接红（扫空 = 假绿）。
#
# 钉的事（每条后面是它守的规矩，出处见 docs/architecture/fal-generation.md）：
#   1. **不弹模态框**：fal 这几个文件里没有 NSAlert / runModal / 任何面板（方案第 9、10 条；要问就走 AISession.ask 的提示条）；
#   2. **HTTP 只经 FalClient**：`queue.fal.run` 和 `URLSession` 只出现在 FalClient.swift（认证头、取消、错误换话都在那里）；
#   3. **Key 只经 FalKeyCache 读**：`FalKeyStore.read(` 只在 FalKeyStore.swift 里；用 Key 的只有生成任务和配旁白两处；
#   4. **先问后花**：生成任务里 `store.decide(` 在 `client.run(` 之前，记账 `reserve(store)` 恰好两处（额度内 / 用户点头之后），
#      问用户走 `AISession.shared.ask`；没做出来才退（`guard !resultReceived`）；
#   5. **提示条上的问题不管这一轮什么状态都摆出来**（AI 等结果时这一轮早「结束」了）；停止 / cancel_job 把问题收回（withdrawQuestions）；
#   6. **配旁白是同步工具，不许停下来等用户**：AIVoiceoverTool / AIFalVoice 里没有 `.ask(`，额度用 `allowsWithoutAsking` 判断，用不了就退档；
#      fal 的声音也只经 `AIAudioFileWriter.writeVoiceover` 落盘（scripts/check-mcp.sh 那条扫描也钉着）；
#   7. **清单跟着 Key 走**：`generate_media` 属于 fal（MCPToolName.provider）、Key 添加 / 删除都同步那个小文件、启动时也对一遍；
#   8. 路由：generate_media 只起任务、不改工程（不排进撤销分组）；任务有 waitingForUser 和取消。
#
# 用法：checks/fal-wiring.sh
set -euo pipefail
cd "$(dirname "$0")/.."

RUN="Sources/SrtFlow/Fal/FalGenerationRun.swift"
TOOL="Sources/SrtFlow/Fal/FalGenerateTool.swift"
CLIENT="Sources/SrtFlow/Fal/FalClient.swift"
KEYS="Sources/SrtFlow/Fal/FalKeyStore.swift"
SETTINGS="Sources/SrtFlow/Fal/FalSettingsStore.swift"
VOICE="Sources/SrtFlow/AIFalVoice.swift"
VOICEOVER="Sources/SrtFlow/AIVoiceoverTool.swift"
SESSION="Sources/SrtFlow/AISession.swift"
BANNER="Sources/SrtFlow/AIActivityBanner.swift"
ROUTER="Sources/SrtFlow/AIToolRouter.swift"
CATALOG="Sources/SrtFlowMCPKit/MCPToolCatalog.swift"
APP="Sources/SrtFlow/SrtFlowApp.swift"
for file in "${RUN}" "${TOOL}" "${CLIENT}" "${KEYS}" "${SETTINGS}" "${VOICE}" "${VOICEOVER}" "${SESSION}" "${BANNER}" "${ROUTER}" "${CATALOG}" "${APP}"; do
  if [ ! -f "${file}" ]; then
    echo "✗ 找不到 ${file} —— 改名了就同步改这里（扫空 = 假绿）" >&2
    exit 1
  fi
done

FAILED=0
fail() { echo "✗ $1" >&2; FAILED=1; }
count() { grep -c -- "$1" "$2" || true; }
line_of() { { grep -n -- "$1" "$2" || true; } | head -1 | cut -d: -f1; }

FAL_FILES=(Sources/SrtFlow/Fal/*.swift "${VOICE}")

# 1. 不弹模态框。
for file in "${RUN}" "${TOOL}" "${VOICE}" "${SETTINGS}"; do
  if grep -nE 'NSAlert|runModal|beginSheetModal|NSOpenPanel|NSSavePanel|\.alert\(|confirmationDialog' "${file}"; then
    fail "${file}：里面弹了模态框 —— 要问用户就走 AISession.ask（提示条上两个按钮），AI 在等的时候弹框没人点"
  fi
done

# 2. HTTP 只经 FalClient。
others="$(grep -l 'queue\.fal\.run\|URLSession' "${FAL_FILES[@]}" | grep -v "^${CLIENT}\$" || true)"
if [ -n "${others}" ]; then
  fail "这些文件自己碰了 fal 的地址 / URLSession：$(tr '\n' ' ' <<<"${others}")—— 请求只经 FalClient（认证头、取消、错误换话都在那里）"
fi

# 3. Key 只经 FalKeyCache 读。
direct="$(grep -ln 'FalKeyStore\.read(' Sources/SrtFlow/*.swift Sources/SrtFlow/*/*.swift | grep -v "^${KEYS}\$" || true)"
if [ -n "${direct}" ]; then
  fail "这些文件直接读了钥匙串：$(tr '\n' ' ' <<<"${direct}")—— 读 Key 只经 FalKeyCache（一次运行最多问钥匙串一次、也就最多弹一次授权框）"
fi
users="$(grep -ln 'FalKeyCache\.shared\.key(' Sources/SrtFlow/*.swift Sources/SrtFlow/*/*.swift | tr '\n' ' ')"
if [ "${users}" != "${VOICE} ${RUN} " ] && [ "${users}" != "${RUN} ${VOICE} " ]; then
  fail "用 Key 的地方应该只有生成任务和配旁白两处，实际是：${users}"
fi

# 4. 先问后花。
DECIDE="$(line_of 'store.decide(' "${RUN}")"
SUBMIT="$(line_of 'client.run(' "${RUN}")"
if [ -z "${DECIDE}" ] || [ -z "${SUBMIT}" ] || [ "${DECIDE}" -ge "${SUBMIT}" ]; then
  fail "${RUN}：花钱的把关（store.decide）必须在提交（client.run）之前"
fi
[ "$(count 'reserve(store)' "${RUN}")" -eq 2 ] \
  || fail "${RUN}：记账 reserve(store) 应恰好两处（额度内直接做 / 用户点头之后）"
[ "$(count 'AISession.shared.ask(' "${RUN}")" -eq 1 ] \
  || fail "${RUN}：超额度 / 没登记单价要问用户，且只走 AISession.shared.ask 一处"
[ "$(count 'guard !resultReceived' "${RUN}")" -eq 1 ] \
  || fail "${RUN}：退账必须只在没拿到结果时（fal 只对做出来的收钱）"
[ "$(count 'recordSpend(' "${RUN}")" -eq 1 ] && [ "$(count 'recordSpend(' "${VOICE}")" -eq 1 ] \
  || fail "记账 recordSpend 只该在 reserve（生成）和配旁白读完一句之后各一处"

# 5. 提示条上的问题。
Q="$(line_of 'if let question = session.question' "${BANNER}")"
S="$(line_of 'switch session.phase' "${BANNER}")"
if [ -z "${Q}" ] || [ -z "${S}" ] || [ "${Q}" -ge "${S}" ]; then
  fail "${BANNER}：要点头的问题必须先于 switch session.phase 摆出来（这一轮「结束」了条也不能把问题收起来）"
fi
grep -q 'withdrawQuestions(owner: job.id)' "${RUN}" || fail "${RUN}：取消任务时没有把挂在条上的问题收回"
grep -q 'while !pendingQuestions.isEmpty { resolveFirst(false) }' "${SESSION}" || fail "${SESSION}：按停止时没有把等着的问题算作「不要」"

# 6. 配旁白是同步工具，不许停下来等用户。
for file in "${VOICEOVER}" "${VOICE}"; do
  if grep -nE '\.ask\(' "${file}"; then
    fail "${file}：配旁白是同步的工具（客户端一分钟左右超时），不许停下来问用户 —— 额度不够就退到下一档"
  fi
done
grep -q 'FalSpendPolicy.allowsWithoutAsking' "${VOICE}" || fail "${VOICE}：能不能用 fal 的声音必须按额度判断（allowsWithoutAsking）"
grep -q 'falAvailable: offer != nil' "${VOICEOVER}" || fail "${VOICEOVER}：挑声音没把「fal 能不能用」传给 AIVoiceChoice.choose"
[ "$(count 'AIAudioFileWriter.writeVoiceover(' "${VOICE}")" -eq 1 ] || fail "${VOICE}：fal 的声音必须经 AIAudioFileWriter.writeVoiceover 落盘（先过一道音量）"

# 7. 清单跟着 Key 走。
grep -Eq 'case \.generateMedia: return \.fal' "${CATALOG}" || fail "${CATALOG}：generate_media 没属于 fal 提供方 —— 没配 Key 也会列出来"
# 调用各占一行（8 格缩进）：Key 存 / 删 / 重新查看，共三处（定义那一行不算）。
[ "$(count '^        syncProviders()$' "${SETTINGS}")" -eq 3 ] || fail "${SETTINGS}：Key 添加 / 删除 / 重新查看之后没有同步「配了哪些提供方」的小文件（应恰好三处调用）"
grep -q 'FalSettingsStore.shared.refreshKeyStatus()' "${APP}" || fail "${APP}：启动时没有对一遍「配了 fal」的小文件"

# 8. 路由与任务。
[ "$(count '\.generateMedia' "${ROUTER}")" -eq 2 ] || fail "${ROUTER}：generate_media 应出现两处（分派、策略：不排撤销分组、不算这一轮的改动）"
if grep -n 'generateMedia' "${ROUTER}" | grep -q 'AIUndoGrouping'; then
  fail "${ROUTER}：generate_media 不改工程，不该包进 AIUndoGrouping（放上时间线是 add_clips 的事）"
fi
grep -q 'waitingForUser: { \[weak self\] in self?.waiting }' "${RUN}" || fail "${RUN}：任务没把「在等用户」交给 AIJobs（AI 会对着 running 干等）"
grep -q 'cancel: { \[weak self\] in self?.cancel() }' "${RUN}" || fail "${RUN}：任务没有取消动作（停止按钮取消不了）"

if [ "${FAILED}" -ne 0 ]; then
  echo "fal 接线守卫失败" >&2
  exit 1
fi
echo "✓ fal 接线守卫通过"
