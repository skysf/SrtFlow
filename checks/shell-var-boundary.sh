#!/usr/bin/env bash
# 仓库里所有 shell 脚本：裸 `$VAR` 后面不许紧跟多字节字符（中文、全角标点）。
#
# bash 展开不带花括号的变量名时，会把后面那个多字节字符的**首字节**也算进名字里：
# `"在 $FILE）"` 去找的是 `FILE\xef`，配上 `set -u` 当场退出 —— 而且这种行多半是
# 失败提示，平时根本跑不到，一出事就是「守卫红了，但打出来的不是那句话」，或者
# 脚本在报错之前先崩了。写成 `${FILE}）` 就没事。
#
# 这是本仓库的结构性陷阱（所有脚本的提示文案都是中文）：2026-08-06 定性、写进
# 教训「上面那条正则可以直接拿来扫」，但一直没做成检查；2026-09-23 在
# checks/timeline-drag-wiring.sh 里又出现了 4 处、scripts/audio-library/ 里 1 处。
# 来龙去脉见 docs/bugfixes/2026-08-06-build-version-and-shell-traps.md。
set -euo pipefail
cd "$(dirname "$0")/.."

# 注释行不算：说明文字里举例写出来的裸变量不会被执行。
HITS="$(git ls-files --cached --others --exclude-standard '*.sh' | while IFS= read -r f; do
  perl -ne 'next if /^\s*#/; print "'"$f"':$.: $_" if /\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7F]/' "$f"
done)"

if [ -n "${HITS}" ]; then
  echo "✗ 这些行里有裸 \$VAR 紧跟多字节字符（bash 会把首字节吃进变量名，set -u 下当场退出），改成 \${VAR}：" >&2
  printf '%s\n' "${HITS}" >&2
  exit 1
fi
echo "✓ shell-var-boundary：没有裸 \$VAR 紧跟多字节字符"
