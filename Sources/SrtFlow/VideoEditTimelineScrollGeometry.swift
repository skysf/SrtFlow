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
@MainActor
final class TimelineScrollGeometry: ObservableObject {
    /// 给「钉住不动」的那两块（轨道头列、标尺）用的推送值。
    /// 手势**不要**读它 —— 那是上一次通知时的值，要现读的用 `offsetX/offsetY`。
    @Published private(set) var offset: CGPoint = .zero

    /// 弱引用：视图树被拆掉时跟着失效，别让它把滚动视图吊住。
    private weak var scrollView: NSScrollView?
    private var boundsObserver: NSObjectProtocol?

    /// 屏幕坐标 → **滚动内容**坐标。指针不在可见内容区里（轨道头列上、时间线
    /// 以外）时返回 nil。
    ///
    /// 给从 Finder 拖文件进来那条路用：它只能是闭包式 `.onDrop`（代理式收不到
    /// 外部拖入，见 `MediaFileDropController.pointer`），拿不到 SwiftUI 给的落点，
    /// 只能现读 `NSEvent.mouseLocation` 再换算。换算放在这儿是因为**整个时间线
    /// 只有这个类碰 `NSScrollView`**。
    func contentPoint(fromScreen screen: CGPoint) -> CGPoint? {
        guard let scrollView, let window = scrollView.window,
              let document = scrollView.documentView else { return nil }
        let inWindow = window.convertPoint(fromScreen: screen)
        let clipView = scrollView.contentView
        // clip view 的 bounds 原点就是滚动量，所以这一下同时判了「在不在视口里」。
        guard clipView.bounds.contains(clipView.convert(inWindow, from: nil)) else { return nil }
        let point = document.convert(inWindow, from: nil)
        // SwiftUI 的滚动内容是翻转坐标系（左上原点），和 `rowLayouts` 一致；
        // 万一哪天不是，这里换算回来，别让落点整个上下颠倒。
        return document.isFlipped
            ? point
            : CGPoint(x: point.x, y: document.bounds.height - point.y)
    }

    /// 由 `TimelineScrollViewAccessor` 在滚动内容里认出滚动视图后挂上来。
    func attach(_ scrollView: NSScrollView?) {
        guard scrollView !== self.scrollView else { return }
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
            self.boundsObserver = nil
        }
        self.scrollView = scrollView
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
