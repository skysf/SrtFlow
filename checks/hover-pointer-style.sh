#!/usr/bin/env bash
# 扫描守卫：悬停指针一律走 SwiftUI 原生 `.pointerStyle(_:)`，不许碰 NSCursor。
#
# 由来：原先六处把手手写 `.onHover { if $0 { c.push() } else { NSCursor.pop() } }`，
# 共用系统**同一个**光标栈，漏押/错弹一次就全局卡住。第一版修法是「自己记账 +
# onDisappear 兜底」，实测见 docs/bugfixes/2026-09-20-hover-cursor-stack.md
# 仍然不对：**拖动一开始 SwiftUI 就发 onHover(false)**，光标在拖到一半时就弹回箭头，
# 而真正该保持的恰恰是拖动全程。记账再精细也救不了——push/pop 这套本来就在跟
# SwiftUI 自己的指针管理抢方向盘。
#
# macOS 15 起 SwiftUI 有 `.pointerStyle(_:)`：指针归视图的区域管，视图挪走/变形/
# 消失/拖动中，全由 SwiftUI 维护，没有全局栈可漏。包的最低系统正好是 15.0。
# 外观零变化，三种都实测对照过是**像素级同图**：
#   .columnResize = NSCursor.resizeLeftRight
#   .rowResize    = NSCursor.resizeUpDown
#   .rectSelection= NSCursor.crosshair
set -euo pipefail
cd "$(dirname "$0")/.."

# **不要用 `git ls-files`**：新写的文件往往还没 add，会被静默跳过（no-hardcoded-fps
# 那条守卫实测踩过，未跟踪期间根本没扫却报「通过」）。用文件系统枚举。
SWIFT_FILES=$(find Sources -name '*.swift' -type f | sort)
fail=0

# 去掉注释行再扫：说明里写「以前是 NSCursor.pop()」是必要的交代，不是违规。
code_of() { grep -vE '^[[:space:]]*(//|\*)' "$1"; }

scan() {
    local pattern="$1" label="$2" hits=""
    for f in $SWIFT_FILES; do
        local found
        found=$(code_of "$f" | grep -nE "$pattern" || true)
        [ -n "$found" ] && hits="$hits\n$(echo "$found" | sed "s|^|    $f:|")"
    done
    if [ -n "$hits" ]; then
        echo "✗ $label"
        printf "%b\n" "$hits"
        fail=1
    fi
}

echo "==> 扫描 NSCursor 的任何用法"
scan 'NSCursor'   "代码里还有 NSCursor（悬停指针一律 .pointerStyle(_:)）"
# push 的 receiver 五花八门（`NSCursor.resizeLeftRight.push()` / `handle.cursor.push()`），
# 光钉 NSCursor 会漏掉后者那种；实测 Sources/ 下 `.push()` 只有光标这一种用途。
scan '\.push\(\)' "代码里还有 .push()（光标栈的老写法）"

# 八处把手各自钉死：路径或样式写错 = 扫了个空文件还是绿的。
echo "==> 钉住八处把手的指针样式"
need() {   # need <文件> <正则> <人话>
    if [ ! -f "$1" ]; then echo "✗ 文件不在：$1"; fail=1; return; fi
    if ! code_of "$1" | grep -cE "$2" >/dev/null; then
        echo "✗ $1 少了 $3（模式 /$2/）"
        fail=1
    fi
}
need Sources/SrtFlow/VideoEditTimelineTransitionMask.swift '\.pointerStyle\(\.columnResize\)' '转场遮罩把手的 .columnResize'
need Sources/SrtFlow/VideoEditTimelineShapeRow.swift       '\.pointerStyle\(\.columnResize\)' '形状轨裁切把手的 .columnResize'
need Sources/SrtFlow/VideoEditTimelineTextRow.swift        '\.pointerStyle\(\.columnResize\)' '文字轨裁切把手的 .columnResize'
need Sources/SrtFlow/VideoEditTimelineClipBlock.swift      '\.pointerStyle\(\.columnResize\)' '片段裁切把手的 .columnResize'
need Sources/SrtFlow/VideoEditTimelineClipBlock.swift      '\.pointerStyle\(project\.activeTool == \.split \? \.rectSelection : nil\)' '刀片十字（条件靠 nil 交回外层）'
need Sources/SrtFlow/VideoEditTimelineRowHeightDrag.swift  '\.pointerStyle\(\.rowResize\)'    '轨道头调行高的 .rowResize'
need Sources/SrtFlow/VideoEditTimelineHeaderColumn.swift   '\.pointerStyle\(lane == nil \? nil : \(dragging \? \.grabActive : \.grabIdle\)\)' '轨道头换位的抓手（不能换位的行 nil 交回外层）'
need Sources/SrtFlow/VideoEditPreviewTransform.swift       '\.pointerStyle\(handle\.pointerStyle\)' '预览变换把手接 handle.pointerStyle'
need Sources/SrtFlow/VideoEditPreviewTransform.swift       'var pointerStyle: PointerStyle'  'FrameHandle 暴露 pointerStyle'

if [ "$fail" -eq 0 ]; then
    echo "✓ 悬停指针全部走 .pointerStyle，没有 NSCursor"
    echo "All checks passed"
else
    echo
    echo "悬停指针一律 .pointerStyle(_:)（nil = 这一处不接管，交回外层）。"
    exit 1
fi
