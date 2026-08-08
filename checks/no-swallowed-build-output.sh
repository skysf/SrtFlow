#!/usr/bin/env bash
# 扫描守卫：脚本里不许再写 `swift build/run … >/dev/null`。
#
# SwiftPM 的编译诊断走 **stdout**，>/dev/null 会把失败吞成无字天书 ——
# CI 首跑 6 项自检齐红、日志里一行编译错误都没有，就是它（见
# docs/bugfixes/2026-08-08-ci-first-run-sdk-and-swallowed-errors.md）。
# 静默成功可以：用 BUILD_OUT="$(swift build … 2>&1)" || { printf … } 的写法，
# 失败时倾倒完整输出。
#
# 用文件系统枚举而不是 git ls-files：未跟踪的新脚本也要盖住。
set -euo pipefail
cd "$(dirname "$0")/.."

violations=""
while IFS= read -r file; do
  # 排除本守卫自己（说明文字里要举反例）。
  [ "${file}" = "./checks/no-swallowed-build-output.sh" ] && continue
  if grep -nE 'swift (build|run)[^|]*>[[:space:]]*/dev/null' "${file}" >/dev/null 2>&1; then
    hits="$(grep -nE 'swift (build|run)[^|]*>[[:space:]]*/dev/null' "${file}")"
    violations="${violations}${file}:
${hits}
"
  fi
done < <(find . -name '*.sh' -not -path './.git/*' -not -path './vendor/*' -not -path './.build/*')

if [ -n "${violations}" ]; then
  echo "✗ 发现把 SwiftPM 输出吞进 /dev/null 的写法（编译错误会无声消失）：" >&2
  printf '%s' "${violations}" >&2
  exit 1
fi
echo "✓ 没有被吞掉的 swift build/run 输出"
echo "All checks passed"
