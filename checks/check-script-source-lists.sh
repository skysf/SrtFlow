#!/usr/bin/env bash
# 扫描守卫：自检脚本的 swiftc 文件清单不许漏掉模型的同伴文件。
#
# 由来（docs/bugfixes/2026-09-18-check-script-source-list-drift.md）：
# 给 `VideoEditModels.swift` 加了一处 `ClipVisibility` 调用，新文件却只加进了两个
# 自检脚本 —— 另外八个 `xcrun swiftc` 的清单里没有它，全部当场编不过。本地只跑了
# 「相关的那两项」，所以一路绿到 CI 才红。
#
# 为什么会有这种清单：被测代码在 SrtFlow 这个 app target 里，SwiftPM 不允许两个
# target 共用同一批源文件，所以每个自检脚本都自己列一份源文件编成独立二进制
#（见 scripts/check-project-file.sh 开头的说明）。清单是手抄的，就会漂。
#
# 同伴关系**从源码现算**，不写死表：模型里引用到、而定义在别的
# `Sources/SrtFlow` 文件里的顶层类型，它们所在的文件就是同伴。下次再给模型添新
# 依赖，这条守卫自己就知道该要哪个文件。
#
# 用法：checks/check-script-source-lists.sh
set -uo pipefail
cd "$(dirname "$0")/.."

# 枢纽文件：几乎每个自检都要编它，也就最容易在它身上漏依赖。
HUB="Sources/SrtFlow/VideoEditModels.swift"
FAILED=0

fail() {
  echo "✗ $1" >&2
  FAILED=1
}

[ -f "$HUB" ] || { fail "找不到 ${HUB}：枢纽文件改名了，这条守卫会扫空 —— 同步改这里"; exit 1; }

# ---- 1. 顶层类型声明表：类型名 → 定义在哪个文件 ----
DECLS="$(mktemp)"
trap 'rm -f "$DECLS"' EXIT
while IFS= read -r file; do
  grep -Eo '^(public )?(final )?(enum|struct|class|protocol) [A-Z][A-Za-z0-9_]*' "$file" \
    | awk -v f="$file" '{ print $NF, f }'
done < <(find Sources/SrtFlow -name '*.swift') | sort -u > "$DECLS"

# ---- 2. 模型引用到了谁（只看真代码，注释里提到名字不算） ----
HUB_CODE="$(sed 's,//.*,,' "$HUB")"
COMPANIONS=""
while read -r type file; do
  [ "$file" = "$HUB" ] && continue
  if printf '%s\n' "$HUB_CODE" | grep -qE "\b${type}\b"; then
    COMPANIONS="${COMPANIONS}${file}
"
  fi
done < "$DECLS"
COMPANIONS="$(printf '%s' "$COMPANIONS" | sort -u)"

if [ -z "$COMPANIONS" ]; then
  fail "一个同伴文件都没算出来：判据失效了（正则改坏了？），这条守卫等于没跑"
  exit 1
fi

# ---- 3. 每个编模型的脚本都得把同伴带齐 ----
#
# 「编它」的判据是 `xcrun swiftc` 那个**续行块**里的源文件行，不是文件里提到过
# 这个路径：扫描守卫的参数行（`require "…" Sources/…swift '正则'`）和本守卫的
# 说明文字都只是提名字，当成编译清单会误红。
swiftc_sources() { # swiftc_sources <脚本> —— 打印它编进自检二进制的源文件
  awk '
    /xcrun swiftc/ { inblock = 1 }
    inblock {
      line = $0
      sub(/[[:space:]]*\\$/, "", line)
      gsub(/^[[:space:]]+/, "", line)
      if (line ~ /\.swift$/) { print line }
      if ($0 !~ /\\$/) { inblock = 0 }
    }
  ' "$1"
}

SCRIPTS=""
for script in scripts/*.sh checks/*.sh; do
  swiftc_sources "$script" | grep -qx "$HUB" \
    && SCRIPTS="${SCRIPTS}${script}
"
done
SCRIPTS="$(printf '%s' "$SCRIPTS")"
[ -n "$SCRIPTS" ] || fail "没有任何自检脚本在编 ${HUB}：清单的扫描目标没了"

for script in $SCRIPTS; do
  LISTED="$(swiftc_sources "$script")"
  for companion in $COMPANIONS; do
    printf '%s\n' "$LISTED" | grep -qx "$companion" \
      || fail "${script} 的源文件清单缺 ${companion}（${HUB} 用到了它，编不过）"
  done
done

if [ "$FAILED" -ne 0 ]; then
  exit 1
fi
COUNT="$(printf '%s\n' "$COMPANIONS" | wc -l | tr -d ' ')"
echo "✓ check-script-source-lists：$(printf '%s\n' "$SCRIPTS" | wc -l | tr -d ' ') 个脚本都带齐了模型的 ${COUNT} 个同伴文件"
