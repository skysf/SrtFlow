#!/usr/bin/env bash
# 跑全部秒级的扫描守卫（checks/*.sh），一个都不漏：推之前、搬代码 / 改名之后先跑它。
#
# 为什么要有这个入口（docs/bugfixes/2026-10-01-pr132-first-ci-run-guard-in-moved-insert.md）：扫描守卫按文件名找接线，
# 把代码搬进新文件之后，守卫还指着旧文件就红 —— 本地凭记忆挑着跑几条守卫，漏掉的那一条只在 CI 上红（2026-09-25 PR #71、
# 2026-09-29 PR #84、2026-10-01 PR #132 三次都是这样）。全部跑一遍只要几十秒，不编译、不碰 .build，可以和编自检的脚本并行。
# `scripts/check-all.sh` 照样逐条跑它们；这里只是本地推之前的快入口。
#
# 用法：scripts/check-guards.sh
set -euo pipefail
cd "$(dirname "$0")/.."

FAILED=()
for guard in checks/*.sh; do
  if output="$(bash "${guard}" 2>&1)"; then
    printf '  ✓ %s\n' "${guard}"
  else
    printf '  ✗ %s\n' "${guard}"
    printf '%s\n' "${output}" | grep -E '✗' | head -n 5 | sed 's/^/      /'
    FAILED+=("${guard}")
  fi
done
if [ "${#FAILED[@]}" -ne 0 ]; then
  echo "✗ check-guards：${#FAILED[@]} 条扫描守卫红了：${FAILED[*]}" >&2
  exit 1
fi
echo "✓ check-guards：全部扫描守卫绿"
