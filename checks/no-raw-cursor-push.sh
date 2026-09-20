#!/usr/bin/env bash
# 扫描守卫：不许再手写裸的光标 push/pop，一律走 `.hoverCursor(_:)`。
#
# 由来：`.onHover { if $0 { c.push() } else { NSCursor.pop() } }` 这个写法全仓有
# **6 处**（转场遮罩把手、片段裁切把手、形状/文字轨把手、标尺、预览变换把手），
# 外加 `VideoEditTimelineClipBlock` 里一份自己记账的刀片十字光标。它们共用系统
# **同一个**光标栈，漏押/错弹一次就是全局卡住：
#   - 视图在悬停中被重建/销毁时 `onHover(false)` 不会来 → 押了没弹，光标卡成
#     左右箭头（现场：拖着改转场时长，遮罩随时长重建）；
#   - 没押过却收到一次 `onHover(false)` → 弹掉的是别人压在栈上的光标。
# 记账只能有一份，就是 `Sources/SrtFlow/HoverCursor.swift`。
#
# **扫描面为什么这么宽**：仓库里字面量 `NSCursor.push()` 出现 **0 次** —— 实际写法
# 是 `NSCursor.resizeLeftRight.push()` / `handle.cursor.push()`，receiver 五花八门。
# 照字面钉 `NSCursor\.push()` 是一条永远绿的假绿。所以这里扫任意 receiver 的
# `.push()`；实测 Sources/ 下 `.push()` 只有光标这一种用途，不会误伤。
# 将来真有别的栈类型要 `push()`，**收窄这条规则时必须连带反向验证**（照 AGENTS.md
# 那条：故意写回裸 push，守卫必须红）。
set -euo pipefail
cd "$(dirname "$0")/.."

# **不要用 `git ls-files`**：新写的文件往往还没 add，会被静默跳过（no-hardcoded-fps
# 那条守卫就实测踩过，未跟踪期间根本没扫却报「通过」）。用文件系统枚举。
HELPER="Sources/SrtFlow/HoverCursor.swift"
SWIFT_FILES=$(find Sources -name '*.swift' -type f | sort)

fail=0

# 去掉注释行再扫：文档/说明里写「以前是 NSCursor.pop()」是必要的说明，不是违规。
scan() {
    local pattern="$1" label="$2" hits=""
    for f in $SWIFT_FILES; do
        [ "$f" = "$HELPER" ] && continue   # 唯一的记账处，豁免
        local found
        found=$(grep -n "$pattern" "$f" 2>/dev/null \
            | grep -v ':[[:space:]]*//' \
            | grep -v ':[[:space:]]*\*' || true)
        [ -n "$found" ] && hits="$hits\n$(echo "$found" | sed "s|^|    $f:|")"
    done
    if [ -n "$hits" ]; then
        echo "✗ $label"
        printf "%b\n" "$hits"
        fail=1
    fi
}

# 守卫自己也要防漏：记账处不在了，上面的豁免就会把整条规则悄悄架空。
if [ ! -f "$HELPER" ]; then
    echo "✗ 记账处不见了：$HELPER"
    echo "  没有它，下面的豁免会让这条守卫扫了个寂寞。"
    exit 1
fi
for sym in 'func hoverCursor' 'private var pushed' 'onDisappear'; do
    if ! grep -q "$sym" "$HELPER"; then
        echo "✗ $HELPER 里找不到 \`$sym\` —— 自记账/兜底被拆了，光标还是会卡"
        fail=1
    fi
done

echo "==> 扫描裸的光标 push/pop（记账处 $HELPER 豁免）"
scan '\.push()'      "手写了光标 push（应改用 .hoverCursor(_:)）"
scan 'NSCursor\.pop()' "手写了 NSCursor.pop()（应改用 .hoverCursor(_:)）"

if [ "$fail" -eq 0 ]; then
    echo "✓ 没有裸的光标 push/pop"
    echo "All checks passed"
else
    echo
    echo "悬停光标一律走 .hoverCursor(_:) / .hoverCursor(_:active:)，见 $HELPER。"
    exit 1
fi
