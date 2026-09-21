#!/usr/bin/env bash
# 扫描守卫：AGENTS.md 是**唯一入口**，那它的索引就必须是全的。
#
# AGENTS.md 只保留「全局规则」+「按任务查文档的索引」，细节全在 docs/ 下。
# 这套分工要成立，有两件事必须一直为真：
#
#   1. docs/ 下的每一份文档都能从 AGENTS.md 找到 —— 否则写了等于没写：
#      别的代理（Codex / Kimi / Gemini…）只读 AGENTS.md，索引里没有的文档它们
#      永远不会打开。**这不是假设，是已经发生过的事**：2026-09-20 那四份案例
#      （播放头断线、转场遮罩漂移、转场预览与成片分叉、悬停光标卡住）写完之后
#      都没进索引，一直到 2026-09-21 才被发现，而其中「播放头断线」那份正好是
#      当天新 bug 的孪生兄弟 —— 索引里有的话，横向那一半当场就能想到。
#   2. 索引里的链接都指向真实存在的文件 —— 文档改名/挪窝之后留下的死链，比没有
#      索引更坏：它会让人以为查过了。
#
# 「手抄的清单会漂」在这个仓库已经栽过两回（见
# docs/bugfixes/2026-09-18-check-script-source-list-drift.md 与
# docs/bugfixes/2026-09-21-source-list-guard-only-watched-the-hub.md），
# 分类目录职责见 AGENTS.md 的「文档目录职责」。

set -euo pipefail
cd "$(dirname "$0")/.."

INDEX="AGENTS.md"
FAILED=0

fail() {
  echo "✗ $1" >&2
  FAILED=1
}

[ -f "$INDEX" ] || { echo "✗ 找不到 ${INDEX}：唯一入口没了，守卫失去目标" >&2; exit 1; }

# AGENTS.md 里所有形如 (path.md) 的链接目标，去重。
LINKS="$(grep -o '([^()]*\.md)' "$INDEX" | tr -d '()' | sort -u)"

# ── 1. docs/ 下的每一份 .md 都必须被索引 ──────────────────────────────
while IFS= read -r doc; do
  printf '%s\n' "$LINKS" | grep -qx "$doc" \
    || fail "${doc} 没有出现在 ${INDEX} 的索引里：只读 AGENTS.md 的代理永远打不开它 —— 按「文档目录职责」补一行到对应的索引小节"
done < <(find docs -name '*.md' | sort)

# ── 2. 索引里的链接都必须指向真实文件 ─────────────────────────────────
# 只管仓库内的相对链接；http(s):// 之类交给别处。
while IFS= read -r link; do
  [ -n "$link" ] || continue
  case "$link" in
    http://*|https://*) continue ;;
  esac
  [ -f "$link" ] \
    || fail "${INDEX} 指向了不存在的 ${link}：死链比没有索引更坏 —— 它会让人以为查过了"
done <<< "$LINKS"

if [ "$FAILED" -ne 0 ]; then
  exit 1
fi
echo "✓ docs-index-drift：docs/ 下 $(find docs -name '*.md' | wc -l | tr -d ' ') 份文档全部在 AGENTS.md 索引中，且无死链"
