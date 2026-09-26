#!/usr/bin/env bash
# 扫描守卫：`PreferenceKey.reduce` 不许写成 `value = nextValue()`（后来的一律盖掉前面的）。
#
# 由来（docs/bugfixes/2026-09-26-stacked-subtitle-frame-lands-on-translation.md）：SwiftUI 合并一个
# 偏好值时，没写这个值的兄弟节点也会给出默认值（量尺寸的键就是 `.zero`）。`value = nextValue()`
# 于是被它们盖成默认值 —— 预览上字幕块的高度一直量成 0，拖框退回最小高度、贴在块底；单行字幕时
# 正好像是对的，原文、译文叠成两行之后，框只框住底下那行（译文），点原文、拖原文全落到译文上。
#
# 合法的写法：忽略默认值（`if next != .zero { value = next }`）、取最大（`value = max(value, nextValue())`）、
# 或者按需要合并。只要不是「无条件拿下一个盖掉」就行。
#
# 用法：checks/preference-reduce-keeps-value.sh
set -euo pipefail
cd "$(dirname "$0")/.."

# **不要用 `git ls-files`**：新写的文件往往还没 add，会被静默跳过。用文件系统枚举。
FILES="$(find Sources -name '*.swift' -type f | LC_ALL=C sort)"
COUNT="$(printf '%s\n' "${FILES}" | grep -c '\.swift$' || true)"
if [ "${COUNT}" -eq 0 ]; then
  echo "✗ 一个 Swift 文件都没扫到 —— 扫空 = 假绿，看看 Sources 是不是改名了" >&2
  exit 1
fi

FOUND=0
FAILED=0
while IFS= read -r file; do
  # 找到 `static func reduce(value:` 那一行，看它后面到收尾大括号为止的函数体。
  bodies="$(awk '
    /static func reduce\(value:/ { inside = 1; depth = 0; print "@@ " FILENAME ":" FNR }
    inside {
      print
      n = gsub(/\{/, "{"); m = gsub(/\}/, "}")
      depth += n - m
      if (depth <= 0 && (n > 0 || m > 0)) inside = 0
    }
  ' "${file}")"
  [ -n "${bodies}" ] || continue
  FOUND=$((FOUND + $(grep -c '^@@ ' <<<"${bodies}")))
  if grep -Eq '^[[:space:]]*value[[:space:]]*=[[:space:]]*nextValue\(\)[[:space:]]*$' <<<"${bodies}"; then
    where="$(grep '^@@ ' <<<"${bodies}" | sed 's/^@@ //' | head -1)"
    echo "✗ ${where}：PreferenceKey.reduce 写成了 value = nextValue()，没写这个值的兄弟节点会拿默认值把量出来的盖掉" >&2
    echo "  改成忽略默认值（if next != .zero { value = next }）或者取最大，见本脚本开头的由来" >&2
    FAILED=1
  fi
done <<<"${FILES}"

if [ "${FOUND}" -eq 0 ]; then
  echo "✗ 一个 PreferenceKey.reduce 都没扫到 —— 扫空 = 假绿，守卫失去目标（改名了就同步改这里）" >&2
  exit 1
fi
if [ "${FAILED}" -ne 0 ]; then
  exit 1
fi
echo "✓ preference-reduce-keeps-value：${FOUND} 个 PreferenceKey.reduce 都不会被默认值盖掉"
