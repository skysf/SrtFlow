#!/usr/bin/env bash
# 扫描守卫：`.contentShape` 不许写在 `.offset` / `.rotationEffect` / `.scaleEffect` /
# `.transformEffect` **之后**（同一条修饰器链里）。
#
# 由来（docs/bugfixes/2026-09-24-text-rotate-handle-hit-area-at-center.md）：这几个都是
# 几何效果 —— **只挪画面，不挪布局框**。写在它们后面的 `contentShape` 按的是没挪过的框：
# 预览里文字选中框的旋转把手 `.offset(y: -上移).contentShape(Circle())`，画出来的黄点在
# 框上方，可点的圆却留在框的正中间 —— 文字正中心有一个看不见的旋转区，用户想拖文字，
# 一按下去变成了旋转；黄点本身反倒点不动。
#
# 同一个道理以前在 popover 上栽过一次（`.offset` 画的块，popover 锚在行首：
# docs/bugfixes/2026-08-12-cue-popover-anchored-at-row-origin.md），这次是它的命中版。
#
# 规则按「同一条修饰器链」判：`.offset(` 那一行之后、**同一缩进**、以 `.` 开头的
# 兄弟修饰器里出现 `.contentShape(` 就红；缩进更深的是参数续行，跳过；空行、缩进变浅、
# 同缩进但不是修饰器，链就断了。注释行不算断链。
#
# 用法：checks/hit-shape-before-offset.sh
set -euo pipefail
cd "$(dirname "$0")/.."

# **不要用 `git ls-files`**：新写的文件往往还没 add，会被静默跳过。用文件系统枚举。
FILES="$(find Sources -name '*.swift' -type f | LC_ALL=C sort)"
COUNT="$(printf '%s\n' "${FILES}" | grep -c '\.swift$' || true)"
if [ "${COUNT}" -eq 0 ]; then
  echo "✗ 一个 Swift 文件都没扫到 —— 扫空 = 假绿，看看 Sources 是不是改名了" >&2
  exit 1
fi

# perl 程序放进带引号的 heredoc：一个字都不经 shell 展开（shell 陷阱 5，
# docs/bugfixes/2026-08-06-build-version-and-shell-traps.md）。
read -r -d '' PROG <<'PERL' || true
my @lines = <>;
# `<>` 一次读完所有文件时拿不到每行属于谁，所以一次只喂一个文件（见下面的循环）。
for my $i (0 .. $#lines) {
    next unless $lines[$i] =~ /^(\s*)\.(offset|rotationEffect|scaleEffect|transformEffect)\(/;
    my ($indent, $effect) = (length($1), $2);
    for my $j ($i + 1 .. $#lines) {
        my $line = $lines[$j];
        last if $line =~ /^\s*$/;
        next if $line =~ m{^\s*//};
        $line =~ /^(\s*)/;
        my $current = length($1);
        last if $current < $indent;
        next if $current > $indent;
        last unless $line =~ /^\s*\./;
        if ($line =~ /^\s*\.contentShape\(/) {
            printf "%d:%d:%s\n", $j + 1, $i + 1, $effect;
        }
    }
}
PERL

HITS=""
while IFS= read -r file; do
  [ -n "${file}" ] || continue
  while IFS= read -r hit; do
    [ -n "${hit}" ] || continue
    line="${hit%%:*}"
    rest="${hit#*:}"
    effect_line="${rest%%:*}"
    effect="${rest#*:}"
    HITS="${HITS}    ${file}:${line}：.contentShape 写在第 ${effect_line} 行的 .${effect} 之后"$'\n'
  done < <(perl -e "${PROG}" "${file}")
done <<< "${FILES}"

if [ -n "${HITS}" ]; then
  echo "✗ .contentShape 写在几何效果之后（可点范围会留在没挪过的框上）："
  printf '%s' "${HITS}"
  echo
  echo "把 .contentShape 挪到 .offset / .rotationEffect / .scaleEffect 前面：先定可点范围，再挪。"
  exit 1
fi

echo "✓ 扫了 ${COUNT} 个 Swift 文件，没有写在几何效果之后的 .contentShape"
echo "All checks passed"
