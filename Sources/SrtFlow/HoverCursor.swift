import AppKit
import SwiftUI

// 悬停光标：谁押的谁弹，视图消失兜底。
//
// 为什么不直接写 `.onHover { if $0 { c.push() } else { NSCursor.pop() } }`：
// 这个写法有两个洞，全 App 的光标栈是**同一个**，漏一次就全局卡住。
//
//  1. **押了没弹**：视图在悬停中被重建/销毁时 `onHover(false)` 根本不会来 ——
//     典型现场是拖着改转场时长，遮罩随时长重建，手一松光标就卡成左右箭头，
//     只能靠划过另一个会 push 的把手把栈冲掉。
//  2. **弹了别人的**：没押过的时候收到一次 `onHover(false)`，那次 pop 弹掉的是
//     **别人**压在栈上的光标。
//
// 所以这里自己记一笔账：`pushed` 只记「我这一处押没押」，只弹自己押的那次，
// 再用 `onDisappear` 给第 1 种情况兜底。
private struct HoverCursorModifier: ViewModifier {
    let cursor: NSCursor
    /// 假 = 这一处完全不接管光标（跟工具模式走的光标用得上）。
    let isActive: Bool

    @State private var hovering = false
    /// 这一处自己有没有押一次在光标栈上。**只弹自己押的那次**。
    @State private var pushed = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                hovering = inside
                sync()
            }
            // 悬停没变、条件变了也要跟着切：指针停在块上把工具从刀片切走，
            // `onHover` 不会再来一次，没有这一步十字光标就卡住了（反向同理，
            // 切成刀片的瞬间指针底下就该变十字，不必先挪开再挪回来）。
            .onChange(of: isActive) { _, _ in sync() }
            // 兜底：悬停中被重建/销毁，上面两个回调都不会来。
            .onDisappear { settle(to: false) }
    }

    private func sync() { settle(to: hovering && isActive) }

    private func settle(to wanted: Bool) {
        guard wanted != pushed else { return }
        if wanted { cursor.push() } else { NSCursor.pop() }
        pushed = wanted
    }
}

extension View {
    /// 悬停时把光标换成 `cursor`，移开或视图消失时换回来。
    func hoverCursor(_ cursor: NSCursor) -> some View {
        modifier(HoverCursorModifier(cursor: cursor, isActive: true))
    }

    /// 条件版：`active` 为假时这一处完全不碰光标栈。
    func hoverCursor(_ cursor: NSCursor, active: Bool) -> some View {
        modifier(HoverCursorModifier(cursor: cursor, isActive: active))
    }
}
