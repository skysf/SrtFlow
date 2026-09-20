#!/usr/bin/env bash
# **转场的接线守卫**：借余料展开（上半），以及「转场可点选可删除」（下半）。
#
# 转场要两段同时在画面上，而编辑器不挪用户摆好的片段 —— 只能向两边借裁掉的
# 素材。这件事由 `TimelineState.expandingTransitionHandles()` 一个函数做完，
# **两条渲染管线必须都在入口调它**：漏掉任意一条，那条管线就会按没展开的几何
# 渲染，于是「预览有淡变、成片是硬切」这类两边不同解的事故重演
#（2026-09-20 查出来的就是这个，事故时导出有相叠判据、预览没有）。
#
# 行为断言在 scripts/check-video-fade.sh（4b / 4c 两节）。那些断言调的是函数
# 本身，**证明不了管线真的接上了** —— 这个脚本补的正是这一刀。
#
# 用法：
#   checks/transition-handles-wiring.sh
#
# 纯静态扫描，不编译、不跑 App。
set -euo pipefail
cd "$(dirname "$0")/.."

CALL="expandingTransitionHandles()"
FAILED=0

for file in Sources/SrtFlow/VideoEditExportGraph.swift \
            Sources/SrtFlow/VideoEditCompositionBuilder.swift; do
    # 只认没被注释掉的调用：`// state = state.expanding…` 不算接上。
    if grep -n "$CALL" "$file" | grep -qv '^\s*[0-9]*:\s*//'; then
        echo "  ✓ $(basename "$file") 调了 $CALL"
    else
        echo "  ✗ $(basename "$file") **没有**调 $CALL —— 这条管线会按没展开的几何渲染" >&2
        FAILED=1
    fi
done

if [ "$FAILED" -ne 0 ]; then
    echo "✗ 转场借余料接线守卫失败：两条渲染管线必须都在入口调 $CALL" >&2
    exit 1
fi

echo "✓ 转场借余料接线守卫通过（两条渲染管线都接上了）"

# ─────────────────────────────────────────────────────────────────────────
# 下半：转场可点选、⌫ 可删除（2026-09-20）
#
# 纯值那一层（`EditSelection` 的六类互斥与 prune、`hasVisibleTransition`）由
# checks/ProjectFile §21 和 checks/TimelineSnap §29 守着。这里守的是**接线** ——
# 那几条断言全过、UI 却没接上去，用户按 ⌫ 照样什么都不会发生。

MASK="Sources/SrtFlow/VideoEditTimelineTransitionMask.swift"
PROJECT="Sources/SrtFlow/VideoEditProject.swift"
INSPECTOR="Sources/SrtFlow/VideoEditInspector.swift"
LIBRARY="Sources/SrtFlow/VideoEditProject+TransitionLibrary.swift"
PICKER="Sources/SrtFlow/VideoEditTransitionPicker.swift"

# 路径写错 = 扫了个空文件还是绿的，先逐个确认文件在。
for f in "$MASK" "$PROJECT" "$INSPECTOR" "$LIBRARY" "$PICKER"; do
    [ -f "$f" ] || { echo "  ✗ 文件不在：$f" >&2; FAILED=1; }
done
[ "$FAILED" -eq 0 ] || exit 1

# 去掉注释行再扫：说明里写「以前是 project.select(outgoing.id」是交代，不是违规。
code_of() { grep -vE "^[[:space:]]*(//|\*)" "$1"; }

# **一律用 `grep -c`，不要用 `grep -q`**：`-q` 一命中就退出，上游的 `grep -v` 当场
# 吃到 SIGPIPE，`set -o pipefail` 再把整条管线判成失败 —— 于是命中反而报「少了」，
# 而且成不成立要看两个进程谁先跑完，时灵时不灵。`-c` 会读完全部输入。
hits() { code_of "$1" | grep -cE "$2" || true; }

need() {   # need <文件> <正则> <人话>
    if [ "$(hits "$1" "$2")" -eq 0 ]; then
        echo "  ✗ $(basename "$1") 少了 $3（模式 /$2/）" >&2
        FAILED=1
    fi
}
deny() {   # deny <文件> <正则> <人话>
    if [ "$(hits "$1" "$2")" -ne 0 ]; then
        echo "  ✗ $(basename "$1") 还留着 $3（模式 /$2/）" >&2
        FAILED=1
    fi
}

# 1) 点遮罩选中的是**转场**，不是出场段。选成出场段的话按 ⌫ 删掉的是整段素材。
need "$MASK" "project\.selectedTransitionSeamID = outgoing\.id" "点遮罩选中转场的接线"
deny "$MASK" "project\.select\(outgoing\.id" "老的「点遮罩选中出场段」写法"
need "$MASK" "isSelected \? Color\.accentColor" "遮罩的选中态描边"

# 2) ⌫ 要有转场这一支，而且 prune 挂在 state 的唯一写入点上。
need "$PROJECT" "if let seamID = selection\.transitionSeamID" "deleteSelected 里的转场分支"
# **别只钉函数名**：定义那一行 `private func pruneTransitionSeamSelection()` 也会
# 命中，于是把 didSet 里的调用删掉照样绿（初版就是这么假绿的，反向探针当场抓到）。
# 钉的是**调用**那一行 —— 行首只有缩进、没有 `func`，而且必须紧跟在
# `pruneMarkerSelection()` 后面：那里是 state 唯一的写入点。
PRUNE_CALL="$(grep -A1 -E "^[[:space:]]+pruneMarkerSelection\(\)$" "$PROJECT" \
    | grep -cE "^[[:space:]]+pruneTransitionSeamSelection\(\)$" || true)"
if [ "$PRUNE_CALL" -eq 0 ]; then
    echo "  ✗ $(basename "$PROJECT") 的 state didSet 里没有紧跟着调 pruneTransitionSeamSelection()" >&2
    FAILED=1
fi
need "$PROJECT" "selection\.pruneTransitionSeam \{ state\.hasVisibleTransition" "prune 的判据钉在「遮罩画不画得出来」上"

# 3) 检查器：选中转场时要有东西可看，否则点了遮罩检查器反而空了。
need "$INSPECTOR" "if let seam = project\.selectedTransitionSeam \{" "检查器的转场分支"
need "$INSPECTOR" "private func transitionSection\(outgoing: EditClip, incoming: EditClip\)" "共用的转场设置块"
# 两条路必须共用同一块 UI —— 写两份迟早分叉。
USES="$(hits "$INSPECTOR" "transitionSection\(")"
if [ "$USES" -lt 3 ]; then
    echo "  ✗ transitionSection 只出现 $USES 次：定义 + 两条调用路径应当至少 3 次" >&2
    FAILED=1
fi

# 4) 库面板：选中的转场排在回退链**最前**，否则用户点着这条缝、面板对着另一条。
need "$LIBRARY" "selectedTransitionSeamIndex\(in: clips\)$" "库面板回退链的第一级"

# 5) 「无」不在库的网格里 —— 它不是一种转场（拖不了、点了是删除）。
deny "$PICKER" "return \[\.none, " "库网格里的「无」那张卡"

if [ "$FAILED" -ne 0 ]; then
    echo "✗ 转场选中/删除接线守卫失败" >&2
    exit 1
fi
echo "✓ 转场选中/删除接线守卫通过（点选、⌫、prune、检查器、库面板、无卡已删）"
