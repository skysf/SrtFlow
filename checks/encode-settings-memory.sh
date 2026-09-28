#!/usr/bin/env bash
# 扫描守卫：压缩 / 烧录两页记住的设置在**队列创建时**读回来，读法只有 EncodeQueueMemory 一处。
#
# 由来（docs/bugfixes/2026-09-27-remembered-subtitle-style-waits-for-burn-in-page.md）：两页各自在 onAppear 里
# 从 UserDefaults 读回设置和字幕样式。剪辑页的字幕预览、剪辑导出、AI 的导出 / 看画面都读烧录队列的样式，
# 可 App 一启动直接进剪辑页（主窗口回到上次的栏目）时烧录页从没出现过 —— 用的是默认样式，要先去烧录页
# 转一圈才换成自己存的那套。
#
# 钉五件事：
#   1. 两个全局队列创建时带着 memory（EncodeQueueMemory.compress / .burnIn）；
#   2. EncodeQueue.init 里调 EncodeQueueMemory.restore；
#   3. 这几个 UserDefaults 键的字面量只在 EncodeQueueMemory.swift 里（页面引用常量，不另写一份）；
#   4. 两页不再自己解码（不出现 JSONDecoder）—— 页面只管改动时写；
#   5. 剪辑页和 AI 用的字幕样式只从 `TimelineState.subtitleStyle(appWide:)` 取（2026-09-28 方案第 54 条：工程可以有
#      自己的样式，AI 改的就是它）：烧录队列的样式在烧录页以外出现的每一行，都只是当「全 App 的」传进去。
#
# 用法：checks/encode-settings-memory.sh
set -euo pipefail
cd "$(dirname "$0")/.."

QUEUE="Sources/SrtFlow/EncodeQueue.swift"
MEMORY="Sources/SrtFlow/EncodeQueueMemory.swift"
PAGES=("Sources/SrtFlow/CompressView.swift" "Sources/SrtFlow/BurnInView.swift")
for file in "${QUEUE}" "${MEMORY}" "${PAGES[@]}"; do
  if [ ! -f "${file}" ]; then
    echo "✗ 找不到 ${file} —— 改名了就同步改这里（扫空 = 假绿）" >&2
    exit 1
  fi
done

FAILED=0
fail() { echo "✗ $1" >&2; FAILED=1; }

# 1. 两个全局队列带着 memory。
grep -Eq 'static let compress = EncodeQueue\(.*memory: EncodeQueueMemory\.compress\)' "${QUEUE}" \
  || fail "${QUEUE}：压缩队列创建时没带 memory: EncodeQueueMemory.compress —— 记住的设置要等打开压缩页才读回来"
grep -Eq 'static let burnIn = EncodeQueue\(.*memory: EncodeQueueMemory\.burnIn\)' "${QUEUE}" \
  || fail "${QUEUE}：烧录队列创建时没带 memory: EncodeQueueMemory.burnIn —— 剪辑页和 AI 会用默认字幕样式"

# 2. init 里读回来。
grep -Eq 'EncodeQueueMemory\.restore\(self, memory\)' "${QUEUE}" \
  || fail "${QUEUE}：EncodeQueue.init 里没调 EncodeQueueMemory.restore(self, memory)"

# 3. 键的字面量只在一处。
for key in compressSettings burnInSettings burnInStyle burnInSoftTrack; do
  others="$(grep -rln --include='*.swift' "\"${key}\"" Sources | grep -v "^${MEMORY}\$" || true)"
  if [ -n "${others}" ]; then
    fail "键 \"${key}\" 在 EncodeQueueMemory.swift 以外也写了字面量：$(tr '\n' ' ' <<<"${others}")—— 引用 EncodeQueueMemory 的常量"
  fi
  if [ "$(grep -c "\"${key}\"" "${MEMORY}" || true)" -ne 1 ]; then
    fail "${MEMORY}：键 \"${key}\" 应该恰好定义一次"
  fi
done

# 4. 页面不自己读回来。
for page in "${PAGES[@]}"; do
  if grep -n 'JSONDecoder' "${page}"; then
    fail "${page}：页面又自己解码记住的设置了 —— 读回来只在 EncodeQueueMemory.restore（队列创建时）"
  fi
done

# 5. 剪辑页和 AI 不直接用烧录队列的样式。烧录页自己、队列、AI 的 burn_subtitles（烧外部文件，本来就是烧录页那套）除外。
STYLE_READS="$(grep -rn --include='*.swift' 'burnInStyle' Sources/SrtFlow \
  | grep -v -e '^Sources/SrtFlow/BurnInView.swift:' -e '^Sources/SrtFlow/EncodeQueue' -e '^Sources/SrtFlow/AIEncodeTools.swift:' \
  | grep -v 'appWide' || true)"
if [ -n "${STYLE_READS}" ]; then
  fail "这几处直接用了烧录页的字幕样式，工程自己的样式（AI 改的）会被忽略 —— 改成 state.subtitleStyle(appWide:)：
${STYLE_READS}"
fi

if [ "${FAILED}" -ne 0 ]; then
  exit 1
fi
echo "✓ encode-settings-memory：两个队列创建时读回记住的设置，键和读法都只有 EncodeQueueMemory 一处；剪辑页和 AI 的字幕样式都经 subtitleStyle(appWide:)"
