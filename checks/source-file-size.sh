#!/usr/bin/env bash
# 扫描守卫：代码文件的行数上限（规范见 docs/architecture/coding-standards.md）。
#
# 2026-09-24 用户定的规范：「代码要模块化，方便后期维护，一个代码文件里面不要太多行」。
# 在那之前 AGENTS.md 只写了「约 800 行警戒线」、没有守卫（只有时间线那一族自己钉着），
# 于是长到 800～2765 行的代码文件攒了十几个。口径：
#
#   - 所有代码文件（.swift / .sh / .py，含测试、检查脚本、还没提交的新文件）超过
#     LIMIT 行就红。空行和注释都算 —— 超了就拆，不许靠删注释、挤行来凑数。
#   - 当时就已经超了的老文件登记在 BASELINE 里，**行数只许降不许涨**：
#       长了                        → 红（新代码进新文件，或同一次改动里拆出等量的行）
#       变短了、基线没跟着改小      → 红（天花板留在老位置，文件能悄悄长回去）
#       降到 LIMIT 以内还挂在基线里 → 红（该从基线里删掉了）
#       基线里的文件已经不在了      → 红（删了，或者改名了 —— 改名就手改那一行的路径）
#     后三种跑 `--update` 就改好（改名除外）。
#   - `--update` 只会把基线改小或删行：不会替新的超标文件登记，也不会替长了的文件抬线。
#
# 用法：
#   checks/source-file-size.sh            # 检查
#   checks/source-file-size.sh --update   # 老文件变短 / 降到上限以内之后，改小基线
#
# 按 docs/bugfixes/2026-08-06-build-version-and-shell-traps.md 写：变量一律 ${VAR}，
# awk 程序放在带引号的 heredoc 里（不经 shell 展开），用 /bin/bash（3.2）调试。
set -euo pipefail
cd "$(dirname "$0")/.."

LIMIT=600
TARGET=400
BASELINE="checks/source-file-size-baseline.txt"

UPDATE=0
case "${1:-}" in
  "") ;;
  --update) UPDATE=1 ;;
  *) echo "✗ 不认识的参数：${1}（用法见文件开头）" >&2; exit 2 ;;
esac

[ -f "${BASELINE}" ] \
  || { echo "✗ 找不到 ${BASELINE}：老文件的基线没了，守卫失去参照" >&2; exit 1; }

# ---- 现状：「行数 路径」，一个文件一行 ----
# 含还没提交的新文件（新文件最容易一口气写长）；工作区里已经删掉的跳过。
FILES="$(git ls-files --cached --others --exclude-standard -- '*.swift' '*.sh' '*.py')" \
  || { echo "✗ git ls-files 失败：不在 git 仓库里？这条守卫靠它列文件" >&2; exit 1; }
CURRENT="$(mktemp)"
trap 'rm -f "${CURRENT}"' EXIT
while IFS= read -r file; do
  [ -n "${file}" ] && [ -f "${file}" ] || continue
  printf '%s %s\n' "$(wc -l < "${file}" | tr -d ' ')" "${file}"
done <<<"${FILES}" > "${CURRENT}"

SCANNED="$(awk 'END { print NR }' "${CURRENT}")"
if [ "${SCANNED}" -eq 0 ]; then
  echo "✗ 一个代码文件都没扫到：扫空了就是假绿 —— 看看 git ls-files 那一行的匹配规则" >&2
  exit 1
fi

# ---- 和基线对账 ----
# 输出一行一个结论：种类 现在的行数 基线的行数 路径（路径放最后，带空格也不怕）。
read -r -d '' COMPARE <<'AWK' || true
function path_of(line) {
  sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", line)
  return line
}
FILENAME == ARGV[1] {
  if ($0 ~ /^[[:space:]]*(#|$)/) next
  base[path_of($0)] = $1 + 0
  next
}
{
  path = path_of($0)
  lines = $1 + 0
  seen[path] = 1
  if (path in base) {
    if (lines > base[path])      print "GREW", lines, base[path], path
    else if (lines <= limit)     print "UNDER", lines, base[path], path
    else if (lines < base[path]) print "SHRANK", lines, base[path], path
    else                         print "KEEP", lines, base[path], path
  } else if (lines > limit) {
    print "NEW", lines, 0, path
  }
}
END {
  for (p in base) if (!(p in seen)) print "GONE", 0, base[p], p
}
AWK
RESULT="$(awk -v limit="${LIMIT}" "${COMPARE}" "${BASELINE}" "${CURRENT}")"

FAILED=0
fail() {
  echo "✗ $1" >&2
  FAILED=1
}

# 这两种 --update 也改不好：只能拆文件。
report_blocking() {
  local kind="$1" lines="$2" base="$3" path="$4"
  case "${kind}" in
    NEW)
      fail "${path} 有 ${lines} 行，超过 ${LIMIT} 行的上限：按职责拆成几个文件（docs/architecture/coding-standards.md 第三节）。不许靠删注释、挤行凑数" ;;
    GREW)
      fail "${path} 是登记过的老超标文件，只许降不许涨：基线 ${base} 行，现在 ${lines} 行（多了 $((lines - base)) 行）—— 新代码放进新文件，或者在同一次改动里从它身上拆出等量的行" ;;
  esac
}

# 这三种是「基线该跟着改了」，跑 --update 就好（改名除外）。
report_stale() {
  local kind="$1" lines="$2" base="$3" path="$4"
  case "${kind}" in
    SHRANK)
      fail "${path} 从 ${base} 行降到了 ${lines} 行，基线没跟着改小：跑 checks/source-file-size.sh --update（不改的话天花板还在老位置，它能悄悄长回去）" ;;
    UNDER)
      fail "${path} 降到了 ${lines} 行（上限 ${LIMIT}），该从基线里删掉了：跑 checks/source-file-size.sh --update" ;;
    GONE)
      fail "基线里的 ${path} 已经不在了：删掉了就跑 --update；改名了就手改 ${BASELINE} 里那一行的路径（改名不算长）" ;;
  esac
}

while read -r kind lines base path; do
  [ -n "${kind}" ] || continue
  report_blocking "${kind}" "${lines}" "${base}" "${path}"
  [ "${UPDATE}" = 1 ] || report_stale "${kind}" "${lines}" "${base}" "${path}"
done <<<"${RESULT}"

if [ "${UPDATE}" = 1 ]; then
  if [ "${FAILED}" -ne 0 ]; then
    echo "✗ 有新的超标文件或长了的老文件：--update 不替它们登记 / 抬线，先拆，基线没动" >&2
    exit 1
  fi
  {
    echo "# 行数超过上限（${LIMIT} 行）的老代码文件，**行数只许降不许涨**。格式：行数 路径。"
    echo "# 由 checks/source-file-size.sh 维护：变短了跑 \`checks/source-file-size.sh --update\` 改小，"
    echo "# 降到上限以内会自动删掉这一行；它不会替新的超标文件登记，也不会替长了的文件抬线。"
    echo "# 改名时手改路径。规范见 docs/architecture/coding-standards.md。"
    awk '$1 == "KEEP" || $1 == "SHRANK" { line = $0; sub(/^[A-Z]+ [0-9]+ [0-9]+ /, "", line); print $2, line }' \
      <<<"${RESULT}" | LC_ALL=C sort -k2
  } > "${BASELINE}.new"
  mv "${BASELINE}.new" "${BASELINE}"
  KEPT="$(awk '!/^#/ && NF' "${BASELINE}" | awk 'END { print NR }')"
  echo "✓ 基线已按现状改小：还有 ${KEPT} 个老文件超过 ${LIMIT} 行"
  exit 0
fi

if [ "${FAILED}" -ne 0 ]; then
  echo "  规范：docs/architecture/coding-standards.md（目标 ≤ ${TARGET} 行，上限 ${LIMIT} 行，老文件只许降）" >&2
  exit 1
fi

KEPT="$(awk '$1 == "KEEP" { n++ } END { print n + 0 }' <<<"${RESULT}")"
OVER_TARGET="$(awk -v t="${TARGET}" -v l="${LIMIT}" '$1 > t && $1 <= l { n++ } END { print n + 0 }' "${CURRENT}")"
echo "✓ source-file-size：扫了 ${SCANNED} 个代码文件，除基线里 ${KEPT} 个老文件外都不超过 ${LIMIT} 行，老文件都没长"
echo "  （${OVER_TARGET} 个在 ${TARGET}～${LIMIT} 行之间：超过目标了，改到它们时顺手按职责拆）"
