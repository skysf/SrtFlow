import AppKit
import SwiftUI

// MARK: - 时间线滚动量的唯一真相
//
// 时间线上只有**框选**用绝对坐标：手势报的是指针在视口里的位置，框要画在滚动
// 内容里，中间差的正是这一份滚动量。别的手势（块的移动、裁切）走 translation
// 这种相对量，同一个错误在它们身上自己抵消，所以这里错了只有框选看得出来。
//
// 2026-09-18 之前这份滚动量是「ScrollView 内一层 GeometryReader 把
// `frame(in: .named(scrollSpace)).minX` 喂进 preference → 写进 `@State`」。
// 那条链路上的值是**异步观察**来的：起手那一拍读到的可能还是上一次布局的数，
// 于是框整体画到指针左边、偏差正好等于当时的滚动量；滚得远一点框直接跑出视口，
// 看起来就是「框选没反应」（docs/bugfixes/2026-09-18-marquee-anchored-at-stale-
// scroll-offset.md）。
//
// 所以滚动量不再缓存：要用的时候从 `NSScrollView` **现读**。手势回调跑在主线程、
// 和 AppKit 同一拍，读到的一定是此刻真正滚到哪儿了。

/// 时间线那个 `NSScrollView` 的现读入口：**整个时间线只有这里碰它**。
///
/// 读（`offsetX`）和推（`scrollHorizontally`）都在这儿，
/// `TimelineAutoScroller` 只剩「什么时候推、推多快」那份心跳。
@MainActor
final class TimelineScrollGeometry {
    /// 弱引用：视图树被拆掉时跟着失效，别让它把滚动视图吊住。
    private weak var scrollView: NSScrollView?

    /// 由 `TimelineScrollViewAccessor` 在滚动内容里认出滚动视图后挂上来。
    func attach(_ scrollView: NSScrollView?) {
        self.scrollView = scrollView
    }

    var isAttached: Bool { scrollView != nil }

    /// 横向滚动量（视图点）。**内容坐标 x = 视口坐标 x + offsetX**。
    ///
    /// 每次都现读，不缓存 —— 这是这个类存在的全部理由。
    var offsetX: Double { Double(scrollView?.contentView.bounds.origin.x ?? 0) }

    /// 推一段横向滚动量，返回推完的位置；已经顶到头（推不动）返回 nil。
    func scrollHorizontally(by dx: Double) -> Double? {
        guard dx != 0,
              let scrollView,
              let documentView = scrollView.documentView else { return nil }
        let clipView = scrollView.contentView
        let minX = documentView.bounds.minX
        let maxX = max(minX, documentView.bounds.maxX - clipView.bounds.width)
        let current = clipView.bounds.origin.x
        let next = min(max(current + dx, minX), maxX)
        guard abs(next - current) > 0.01 else { return nil }
        clipView.scroll(to: NSPoint(x: next, y: clipView.bounds.origin.y))
        scrollView.reflectScrolledClipView(clipView)
        return next
    }
}

/// 把时间线那个 `NSScrollView` 交给上面的几何入口（和自动滚动的心跳）。
/// 放在滚动内容里，`enclosingScrollView` 直接就是它 —— 不用像捏合那样按坐标
/// hitTest 去找。
struct TimelineScrollViewAccessor: NSViewRepresentable {
    let geometry: TimelineScrollGeometry
    let scroller: TimelineAutoScroller

    func makeNSView(context: Context) -> ScrollViewProbe {
        let view = ScrollViewProbe(frame: .zero)
        view.onAttach = attach
        return view
    }

    func updateNSView(_ nsView: ScrollViewProbe, context: Context) {
        nsView.onAttach = attach
        attach(nsView.enclosingScrollView)
    }

    /// 视图树被拆掉（切栏目、关窗）时把滚动视图撤下来，心跳跟着停。
    static func dismantleNSView(_ nsView: ScrollViewProbe, coordinator: ()) {
        nsView.onAttach?(nil)
        nsView.onAttach = nil
    }

    private func attach(_ scrollView: NSScrollView?) {
        geometry.attach(scrollView)
        scroller.attach(scrollView == nil ? nil : geometry)
    }

    @MainActor
    final class ScrollViewProbe: NSView {
        var onAttach: ((NSScrollView?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onAttach?(enclosingScrollView)
        }

        /// 纯参照物，事件一概不碰。
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
