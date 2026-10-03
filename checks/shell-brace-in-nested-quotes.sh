#!/usr/bin/env bash
# shell 脚本里，命令替换「"$(…)"」里面又套着一段带花括号和逗号的双引号字符串（"…{a, b}…"）时，macOS 自带的
# /bin/bash 3.2 会把它当成花括号展开、拆成几个词 —— 本机 PATH 上的 bash 5 不会。拆开之后：
# - 放在 `[ "$(…)" -ne 1 ]` 里，`[` 收到多出来的参数，报「too many arguments」、返回 2，`if` 走 else ——
#   **守卫一声不吭，永远不红**（2026-10-03：scripts/check-mcp.sh 那条撤销分组扫描就这样在 CI 上从来没生效过，
#   docs/bugfixes/2026-10-03-check-mcp-undo-scan-split-by-brace-expansion.md）；
# - 用在别处同样是多跑一遍命令、拿到错的结果。
# CI 的 run_check 一律交给 /bin/bash 跑（docs/bugfixes/2026-08-06-build-version-and-shell-traps.md 陷阱 5），
# 但这一类不报错退出、只在 stderr 打一行，那道防线挡不住，所以单独查（陷阱 6）。
#
# 正确写法：先赋给变量（赋值的右边不做花括号展开）：`found="$(grep -c "…{a, b}…" file || true)"`，
# 再 `[ "${found}" -ne 1 ]`；或者把带花括号的那段写进单引号。
#
# 查法：不是注释、也不是「变量=」开头的行里，`"$(` 后面出现一段双引号字符串，里面有 { … , … }。
# 已知的盲区：命令替换跨了好几行、花括号拼在变量里（"${PATTERN}"）查不到 —— 本仓库目前没有。
set -euo pipefail
cd "$(dirname "$0")/.."

# perl 程序放进带引号的 heredoc：一个字都不经 shell 展开（陷阱 5 的写法）。
read -r -d '' PROG <<'PERL' || true
next if /^\s*#/;
next if /^\s*(?:local\s+|export\s+)?[A-Za-z_][A-Za-z0-9_]*="\$\(/;
print "$ARGV:$.: $_" if /"\$\(.*"[^"]*\{[^"]*,[^"]*\}[^"]*"/;
close ARGV if eof;
PERL

FILES=()
while IFS= read -r file; do
  [ -f "${file}" ] && FILES+=("${file}")
done < <(git ls-files --cached --others --exclude-standard '*.sh')
if [ "${#FILES[@]}" -eq 0 ]; then
  echo "✗ shell-brace-in-nested-quotes：一个 .sh 都没扫到（扫空 = 假绿）" >&2
  exit 1
fi

HITS="$(perl -ne "${PROG}" "${FILES[@]}")"
if [ -n "${HITS}" ]; then
  echo "✗ 这些行的「\"\$(…)\"」里套着带 {…,…} 的双引号字符串：CI 的 /bin/bash 3.2 会把它花括号展开、拆成几个词" >&2
  echo "  （放在 [ ] 里就是 too many arguments、if 走 else，守卫永远不红）。先赋给变量再比较，或者把那段写进单引号：" >&2
  printf '%s\n' "${HITS}" >&2
  exit 1
fi
echo "✓ shell-brace-in-nested-quotes：扫了 ${#FILES[@]} 个 .sh，没有会被 bash 3.2 花括号展开拆开的命令替换"
