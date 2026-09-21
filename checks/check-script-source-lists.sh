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
# 同伴关系**从源码现算**，不写死表：某个文件里引用到、而定义在别的
# `Sources/SrtFlow` 文件里的顶层类型，它们所在的文件就是同伴。下次再添新依赖，
# 这条守卫自己就知道该要哪个文件。
#
# **对清单里的每一个文件都算一遍，不是只算枢纽文件**（2026-09-21 扩宽）：
# 上一版只盯着 `VideoEditModels.swift`，于是「`VideoEditExportGraph.swift` 用到了
# 新的 `FilterLUT`」「`VideoPreviewView.swift` 用到了新的 `FilterStack`」这两类
# 漏项它一个都看不见 —— 本地全绿、CI 六项当场编不过。详见
# docs/bugfixes/2026-09-21-check-source-list-guard-only-watched-the-hub.md。
#
# 已知的盲区：**只定义 extension、不定义顶层类型的文件**这条守卫认不出来
# （没有类型名可匹配）。所以新功能别开「只有 extension」的文件 —— 要么和类型
# 定义放同一个文件，要么里面至少有一个顶层类型。
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
while IFS= read -r file; do
  grep -Eo '^(public )?(final )?(enum|struct|class|protocol) [A-Z][A-Za-z0-9_]*' "$file" \
    | awk -v f="$file" '{ print $NF, f }'
done < <(find Sources/SrtFlow -name '*.swift') | LC_ALL=C sort -u > "$DECLS"

# ---- 2. 某个文件引用到了谁（只看真代码，注释里提到名字不算） ----
# 逐个类型去 grep 一遍文件是 O(类型 × 文件 × 脚本)，实测跑不完（150 个类型 ×
# 150 个文件）。改成：把文件里出现的大写标识符抽一次，再和类型表 join。
# 结果按文件缓存 —— 同一个文件会被十几个脚本的清单问到。
CACHE="$(mktemp -d)"
trap 'rm -f "$DECLS"; rm -rf "$CACHE"' EXIT

companions_of() { # companions_of <文件> —— 打印它必须带上的同伴文件
  KEY="$CACHE/$(printf '%s' "$1" | tr '/' '_')"
  if [ ! -f "$KEY" ]; then
    sed 's,//.*,,' "$1" \
      | grep -oE '\b[A-Z][A-Za-z0-9_]*\b' \
      | LC_ALL=C sort -u \
      | LC_ALL=C join - "$DECLS" \
      | awk -v self="$1" '$2 != self { print $2 }' \
      | LC_ALL=C sort -u > "$KEY"
  fi
  cat "$KEY"
}

HUB_COMPANIONS="$(companions_of "$HUB" | sort -u)"
if [ -z "$HUB_COMPANIONS" ]; then
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
  for companion in $HUB_COMPANIONS; do
    printf '%s\n' "$LISTED" | grep -qx "$companion" \
      || fail "${script} 的源文件清单缺 ${companion}（${HUB} 用到了它，编不过）"
  done
done

# ---- 4. 清单里**每一个**文件的同伴也得齐 ----
#
# 这一节是 2026-09-21 补的。只盯枢纽文件的话，「导出图用到了新的 LUT 引擎」
# 这类漏项一个都看不见。判据同上：清单里的文件引用到了谁，谁就得也在清单里。
#
# 扫的是 `Sources/SrtFlow` 下的**所有** swiftc 清单，不限于编枢纽文件的那些。
for script in scripts/*.sh checks/*.sh; do
  LISTED="$(swiftc_sources "$script" | grep '^Sources/SrtFlow/' || true)"
  [ -n "$LISTED" ] || continue
  for listed in $LISTED; do
    for companion in $(companions_of "$listed"); do
      printf '%s\n' "$LISTED" | grep -qx "$companion" \
        || fail "${script} 的源文件清单缺 ${companion}（${listed} 用到了它，编不过）"
    done
  done
done

if [ "$FAILED" -ne 0 ]; then
  exit 1
fi
COUNT="$(printf '%s\n' "$HUB_COMPANIONS" | wc -l | tr -d ' ')"
echo "✓ check-script-source-lists：$(printf '%s\n' "$SCRIPTS" | wc -l | tr -d ' ') 个脚本带齐了模型的 ${COUNT} 个同伴文件，各清单内部的依赖也闭合"
