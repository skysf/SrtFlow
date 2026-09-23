#!/usr/bin/env bash
# 开着 pipefail 的 shell 脚本里，管道下游不许用 `grep -q`。
#
# `grep -q` 读到第一处匹配就退出；上游（printf / grep -v / awk …）要是还没写完，下一次
# write 就吃 SIGPIPE（bash 的 printf 报 "write error: Broken pipe"），`pipefail` 再把整条
# 管道判成失败 —— **命中了反而报没命中**。上游一次写得完就没事，所以平时几千次都不出事：
# 内容超过管道缓冲（64KB）时每次必红，小内容时看两个进程谁先跑完，本地跑不出来、CI 上
# 偶尔红一次。2026-09-23 就这样在 CI 上把 check-script-source-lists 判红了（案例
# docs/bugfixes/2026-09-23-grep-q-sigpipe-false-red.md）。
#
# 两种正确写法：
# - 查一个变量里有没有：`grep -q 'x' <<<"$BODY"`（here-string，没有管道）；
# - 查一条管道的输出：`… | grep -c 'x' >/dev/null`（-c 会把输入读完）。
#
# `|` 写在上一行行尾、`grep -q` 在下一行开头的也查。已知的盲区：`grep` 被包进变量或
# 别名（`$GREP -q`）、`xargs grep -q` 这类间接调用查不到 —— 本仓库目前没有。
set -euo pipefail
cd "$(dirname "$0")/.."

# 只查开着 pipefail 的脚本：没开的话管道的退出码就是 grep 自己的，SIGPIPE 不影响结论。
# 注释行不算（说明文字里举例写出来的不会被执行）。
HITS="$(git ls-files --cached --others --exclude-standard '*.sh' | while IFS= read -r f; do
  [ -f "$f" ] || continue
  grep -Eq '^[^#]*set -[A-Za-z]*o[[:space:]]+pipefail|^[^#]*set -o pipefail' "$f" || continue
  perl -ne '
    BEGIN { $prev = "" }
    if (/^\s*#/) { next }
    my $line = $_;
    my $hit = 0;
    # 同一行里：| grep <选项…> —— 选项里带 q（-q / -qE / -vq …）或 --quiet / --silent
    while ($line =~ /\|\s*grep((?:\s+(?:-[A-Za-z]+|--quiet|--silent))+)/g) {
      $hit = 1 if $1 =~ /(?:^|\s)-[A-Za-z]*q|--quiet|--silent/;
    }
    # 上一行以 | 结尾（可带续行符），这一行以 grep -q 开头
    if ($prev =~ /\|\s*\\?\s*$/ && $line =~ /^\s*grep((?:\s+(?:-[A-Za-z]+|--quiet|--silent))+)/) {
      $hit = 1 if $1 =~ /(?:^|\s)-[A-Za-z]*q|--quiet|--silent/;
    }
    print "'"$f"':$.: $line" if $hit;
    $prev = $line;
  ' "$f"
done)"

if [ -n "${HITS}" ]; then
  echo "✗ 这些行在 pipefail 下把管道接进了 grep -q（命中后上游吃 SIGPIPE，整条管道判失败 → 时灵时不灵的假红）。" >&2
  echo "  查变量改成 grep -q 'x' <<<\"\$VAR\"；查管道输出改成 … | grep -c 'x' >/dev/null：" >&2
  printf '%s\n' "${HITS}" >&2
  exit 1
fi
echo "✓ shell-pipe-grep-q：开着 pipefail 的脚本里没有管道接 grep -q"
