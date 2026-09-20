#!/usr/bin/env bash
# **转场借余料的接线守卫**。
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
