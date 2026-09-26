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
// 所以滚动量分成两路，各用各的：
//
// - **手势要的**：`offsetX` / `offsetY` 每次从 `NSScrollView` **现读**。手势回调
//   跑在主线程、和 AppKit 同一拍，读到的一定是此刻真正滚到哪儿了。
// - **画面要的**：钉在视口上的轨道头列和标尺得跟着滚动量重画，那是**推**的语义，
//   靠 `offset` 这个 `@Published`（由 clip view 的 boundsDidChange 喂）。
//   **只有那两块订阅它**（`@ObservedObject`）—— 时间线主体用 `@State` 持有这个
//   对象但不订阅，否则滚动的每一帧都会把整棵时间线视图树重建一遍。

/// 时间线那个 `NSScrollView` 的现读入口：**整个时间线只有这里碰它**。
///
/// 读（`offsetX` / `offsetY`）和推（`scrollHorizontally` / `scrollVertically`）
/// 都在这儿，`TimelineAutoScroller` 只剩「什么时候推、推多快」那份心跳。
/// 缩放保持锚点（`keepAnchored`）和「窗口里这一点落在时间线的哪儿」（`location`）也在这儿。
@MainActor
final class TimelineScrollGeometry: ObservableObject {
    /// 给「钉住不动」的那两块（轨道头列、标尺）用的推送值。
    /// 手势**不要**读它 —— 那是上一次通知时的值，要现读的用 `offsetX/offsetY`。
    @Published private(set) var offset: CGPoint = .zero

    /// 此刻挂着滚动视图的那一份。编辑器里只有一条时间线；工具栏的缩放、⌘V 找指针都在时间线的
    /// 视图树外面，拿不到它的 `@State`，从这儿拿。弱引用：时间线拆掉就跟着没了。
    private(set) static weak var live: TimelineScrollGeometry?

    /// 弱引用：视图树被拆掉时跟着失效，别让它把滚动视图吊住。
    private weak var scrollView: NSScrollView?
    private var boundsObserver: NSObjectProtocol?
    /// `keepAnchored` 的补挪只认最新一次（连续缩放时前面几拍的补挪作废）。
    private var anchorGeneration = 0

    /// 由 `TimelineScrollViewAccessor` 在滚动内容里认出滚动视图后挂上来。
    func attach(_ scrollView: NSScrollView?) {
        guard scrollView !== self.scrollView else { return }
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
            self.boundsObserver = nil
        }
        self.scrollView = scrollView
        if scrollView != nil {
            Self.live = self
        } else if Self.live === self {
            Self.live = nil
        }
        guard let clipView = scrollView?.contentView else {
            offset = .zero
            return
        }
        clipView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.offset = clipView.bounds.origin
            }
        }
        offset = clipView.bounds.origin
    }

    deinit {
        // deinit 可能不在主线程：只撤通知，不碰别的状态（同 TimelineAutoScroller）。
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
    }

    var isAttached: Bool { scrollView != nil }

    /// 时间线所在的窗口（⌘V 把屏幕上的指针位置换算进来用）。
    var window: NSWindow? { scrollView?.window }

    /// 横向滚动量（视图点）。**内容坐标 x = 视口坐标 x + offsetX**。每次现读。
    var offsetX: Double { Double(scrollView?.contentView.bounds.origin.x ?? 0) }

    /// 纵向滚动量（视图点）。**内容坐标 y = 视口坐标 y + offsetY**。每次现读。
    /// 轨道多到一屏放不下时才非零（2026-09-18 起时间线可以上下滚）。
    var offsetY: Double { Double(scrollView?.contentView.bounds.origin.y ?? 0) }

    /// 可见视口的尺寸（自动滚动判断指针到没到边用）。
    var viewportSize: CGSize { scrollView?.contentView.bounds.size ?? .zero }

    /// 推一段横向滚动量，返回推完的位置；已经顶到头（推不动）返回 nil。
    func scrollHorizontally(by dx: Double) -> Double? {
        scroll(dx: dx, dy: 0).map { Double($0.x) }
    }

    /// 推一段纵向滚动量，返回推完的位置；顶到头返回 nil。
    func scrollVertically(by dy: Double) -> Double? {
        scroll(dx: 0, dy: dy).map { Double($0.y) }
    }

    /// 把横向滚动量挪到 x（播放跟随用），可带一段短动画。
    func scrollHorizontally(to x: Double, animated: Bool) {
        guard let scrollView, let documentView = scrollView.documentView else { return }
        let clipView = scrollView.contentView
        let minX = documentView.bounds.minX
        let maxX = max(minX, documentView.bounds.maxX - clipView.bounds.width)
        let target = NSPoint(x: min(max(x, minX), maxX), y: clipView.bounds.origin.y)
        guard animated else {
            clipView.scroll(to: target)
            scrollView.reflectScrolledClipView(clipView)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            clipView.animator().setBoundsOrigin(target)
        }
        scrollView.reflectScrolledClipView(clipView)
    }

    /// 窗口里的一点（窗口坐标）落在时间线的**可见视口**里吗；在的话给出它的视口坐标和内容坐标
    /// （内容坐标 = 视口坐标 + 滚动量，§5b）。不在这个窗口、落在视口外面（轨道头列、工具栏）都是 nil。
    /// 标尺钉在视口顶上、也在视口里 —— 算不算「在轨道上」由调用方按行判。
    func location(ofWindowPoint point: NSPoint, in window: NSWindow?) -> TimelineViewportPoint? {
        guard let scrollView, let window, scrollView.window === window else { return nil }
        let clipView = scrollView.contentView
        let local = clipView.convert(point, from: nil)
        guard clipView.bounds.contains(local) else { return nil }
        let viewport = CGPoint(
            x: local.x - clipView.bounds.minX,
            // SwiftUI 的滚动内容是翻转的（y 朝下），和别处「内容 y = 视口 y + offsetY」同一个口径。
            y: clipView.isFlipped ? local.y - clipView.bounds.minY : clipView.bounds.maxY - local.y
        )
        return TimelineViewportPoint(
            viewport: viewport,
            content: CGPoint(x: viewport.x + offsetX, y: viewport.y + offsetY)
        )
    }

    /// 缩放保持锚点：把滚动量挪到 (x, y)，nil 的那一轴一个字都不碰（§5b 最后一条）。
    ///
    /// **同一拍先挪一次，下一轮 main loop 再挪一次**，两次是同一个绝对位置（幂等）：
    /// 改完比例 / 行高的这一拍，SwiftUI 还没按新尺寸排版，放大时目标可能被旧的内容尺寸夹住；
    /// 排完版之后那一次才落得准。只挪后一次的话，排版和补挪之间会有一帧画在左边缘为锚的位置上
    /// （看起来是「一抖」）。连续缩放时只有最新那一拍的补挪生效。
    func keepAnchored(x: Double?, y: Double?) {
        scroll(toX: x, y: y)
        anchorGeneration += 1
        let generation = anchorGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == self.anchorGeneration else { return }
            self.scroll(toX: x, y: y)
        }
    }

    /// 挪到绝对位置，夹进可滚范围；nil 的那一轴原样不动。
    private func scroll(toX x: Double?, y: Double?) {
        guard x != nil || y != nil,
              let scrollView,
              let documentView = scrollView.documentView else { return }
        let clipView = scrollView.contentView
        let maxX = max(documentView.bounds.minX, documentView.bounds.maxX - clipView.bounds.width)
        let maxY = max(documentView.bounds.minY, documentView.bounds.maxY - clipView.bounds.height)
        let current = clipView.bounds.origin
        let next = NSPoint(
            x: x.map { min(max($0, documentView.bounds.minX), maxX) } ?? current.x,
            y: y.map { min(max($0, documentView.bounds.minY), maxY) } ?? current.y
        )
        guard abs(next.x - current.x) > 0.01 || abs(next.y - current.y) > 0.01 else { return }
        clipView.scroll(to: next)
        scrollView.reflectScrolledClipView(clipView)
    }

    /// 两个方向共用的推：夹进可滚范围，没真的动就返回 nil（心跳据此停掉）。
    private func scroll(dx: Double, dy: Double) -> CGPoint? {
        guard dx != 0 || dy != 0,
              let scrollView,
              let documentView = scrollView.documentView else { return nil }
        let clipView = scrollView.contentView
        let maxX = max(documentView.bounds.minX, documentView.bounds.maxX - clipView.bounds.width)
        let maxY = max(documentView.bounds.minY, documentView.bounds.maxY - clipView.bounds.height)
        let current = clipView.bounds.origin
        // **没在推的那个轴一个字都不许碰**（连夹一下都不行）。内容比视口窄时
        // SwiftUI 会把它居中，那一轴的 origin 是负的；顺手夹进 [min, max] 会把
        // 它按回 0 —— 表现就是「纵向自动滚动那一拍，整条时间线横着跳了一大段」
        //（2026-09-18 真窗口实测到的）。
        let next = NSPoint(
            x: dx == 0 ? current.x : min(max(current.x + dx, documentView.bounds.minX), maxX),
            y: dy == 0 ? current.y : min(max(current.y + dy, documentView.bounds.minY), maxY)
        )
        guard abs(next.x - current.x) > 0.01 || abs(next.y - current.y) > 0.01 else { return nil }
        clipView.scroll(to: next)
        scrollView.reflectScrolledClipView(clipView)
        return next
    }
}

/// 窗口里的一点在时间线上的两种坐标（`TimelineScrollGeometry.location`）。
struct TimelineViewportPoint {
    /// 相对可见视口左上角。
    var viewport: CGPoint
    /// 相对滚动内容左上角：x / pps 就是时刻，y 对着 `rowLayouts` 的行。
    var content: CGPoint
}

/// 把时间线那个 `NSScrollView` 交给上面的几何入口（和自动滚动的心跳）。
/// 放在滚动内容里，`enclosingScrollView` 直接就是它。**别按坐标 hitTest 去找**：
/// 捏合缩放以前就是那样找的，传错了坐标系（翻转的根视图），一直找不到时间线
/// （docs/bugfixes/2026-09-26-pinch-zoom-anchor-never-applied.md）。
struct TimelineScrollViewAccessor: NSViewRepresentable {
    let geometry: TimelineScrollGeometry
    let scroller: TimelineAutoScroller

    func makeNSView(context: Context) -> ScrollViewProbe {
        let view = ScrollViewProbe(frame: .zero)
        view.onAttach = attach
        return view
    }

    func updateNSView(_ nsView: ScrollViewProbe, context: Context) {
        PerfCounters.update(Self.self)
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
