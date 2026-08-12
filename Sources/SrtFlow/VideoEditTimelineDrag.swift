import AppKit
import SwiftUI

// MARK: - 剪辑拖动的一轮会话
//
// 长期约束见 docs/architecture/timeline-drag-gestures.md：
// 拖动**过程**中不写 `TimelineState`，块画在哪只由这里的 `offset` 决定。

/// 一轮拖动的会话：冻结的输入（`plan`）+ 手势进度。剪辑和形状共用同一套。
///
/// 松手时拿 `resolution` 去落一次。**渲染和落地是同一份解析结果** ——
/// 不许在 commit 里再算一遍位置。
struct ClipDragSession {
    /// 这一轮从哪一类块起手（落地入口不同，其余一模一样）。
    /// 形状和字幕 cue 走同一个落地入口（`commitFreeDrag`）：两者都不跨轨、
    /// 不插空，区别只在落地时改的字段，而那一步在 `TimelineState.move` 里。
    enum Subject: Equatable {
        case clip(slot: TrackSlot)
        case shape
        case subtitleCue
    }

    let subject: Subject
    /// 手势开始时冻结的全部输入。
    let plan: ClipDragPlan
    /// 手势开始时的横向滚动量：边缘自动滚动把内容抽走时要补回来。
    let originScrollOffset: Double

    /// 最近一次手势位移。自动滚动那一拍指针根本没动，得靠它重算落点。
    private(set) var translation: CGSize = .zero
    /// 这一拍的落点解析（位移 / 对齐线 / 磁吸插入位置）。
    private(set) var resolution: DragResolution

    init(subject: Subject, plan: ClipDragPlan, originScrollOffset: Double) {
        self.subject = subject
        self.plan = plan
        self.originScrollOffset = originScrollOffset
        self.resolution = DragResolution(delta: 0, guides: [], mainInsertion: nil)
    }

    var draggedID: UUID { plan.draggedID }
    /// 跟着一起动的块（含被拖的那个）。
    var movingIDs: Set<UUID> { Set(plan.members.map(\.id)) }
    /// 所有成员的渲染位移（秒）：整组平移同一个值。
    var offset: Double { resolution.delta }
    /// 被拖块此刻的落点与终点（弹性尾部要按终点算）。
    var start: Double { plan.draggedSpan.start + resolution.delta }
    var end: Double { plan.draggedSpan.end + resolution.delta }
    var guides: [Double] { resolution.guides }
    /// 磁吸主轨松手会插进的那条缝（自由落点轨为 nil）。
    var mainInsertionTime: Double? { resolution.mainInsertion?.time }
    /// 能不能把块拖到现有内容之外（弹性尾部）。
    var allowsFreeLanding: Bool { plan.allowsFreeLanding }

    var clipSlot: TrackSlot? {
        if case .clip(let slot) = subject { return slot }
        return nil
    }

    /// 重算落点。`scrollOffset` 变了但 `translation` 没变，就是自动滚动那一拍。
    mutating func update(translation: CGSize, scrollOffset: Double, pixelsPerSecond: Double) {
        self.translation = translation
        // 内容在指针底下被滚走了多少，就要额外补多少 —— 不补的话自动滚动期间
        // 块会跟着内容一起漂，指针指的位置和落点对不上。
        let scrolled = scrollOffset - originScrollOffset
        let desired = (translation.width + scrolled) / max(pixelsPerSecond, 1)
        resolution = plan.resolve(desiredDelta: desired, pixelsPerSecond: pixelsPerSecond)
    }
}

// MARK: - 对齐参考线

/// 拖动时亮起的对齐线：块的某条边和别的东西对齐了才画，铺满时间线全高，
/// 所以跨轨对齐一眼能看出来。不拦事件。
struct TimelineAlignmentGuides: View {
    let times: [Double]
    let pixelsPerSecond: Double

    var body: some View {
        ForEach(times, id: \.self) { time in
            Rectangle()
                .fill(.yellow)
                .frame(width: 1)
                .offset(x: time * pixelsPerSecond)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - 拖到边缘自动滚动

/// 拖动到视口左右边缘时自动横向滚动。
///
/// 走 AppKit 直接推 `NSScrollView`：SwiftUI 的 `ScrollViewReader` 只能滚到某个
/// 锚点视图，做不出「每帧推十几个点」的连续位移；更要紧的是指针**停在边缘不动**
/// 时 `DragGesture` 一个事件都不发，只能由这里的心跳自己驱动重算。
@MainActor
final class TimelineAutoScroller {

    /// 触发自动滚动的边缘宽度（视图点）。
    static let edgeWidth: Double = 44
    /// 完全贴边时的速度（点/秒）。中间按penetration平方渐进，刚进边缘时很慢。
    static let maxSpeed: Double = 900

    private weak var scrollView: NSScrollView?
    private var timer: Timer?
    private var direction: Double = 0
    private var speed: Double = 0
    private var onScroll: ((Double) -> Void)?

    func attach(_ scrollView: NSScrollView?) {
        self.scrollView = scrollView
        if scrollView == nil { stop() }
    }

    deinit {
        // deinit 可能不在主线程：只 invalidate 已调度的 timer，不碰别的状态。
        timer?.invalidate()
    }

    /// 每次拖动回调都调一次。`pointerX` 是指针在**可见视口**里的 x。
    /// 进边缘就开始滚，离开边缘就停；`onScroll` 拿到新的滚动量去重算落点。
    func update(pointerX: Double, viewportWidth: Double, onScroll: @escaping (Double) -> Void) {
        self.onScroll = onScroll
        guard viewportWidth > Self.edgeWidth * 2 else { return stop() }

        let leftDepth = Self.edgeWidth - pointerX
        let rightDepth = pointerX - (viewportWidth - Self.edgeWidth)
        if leftDepth > 0 {
            direction = -1
            speed = ramp(leftDepth)
        } else if rightDepth > 0 {
            direction = 1
            speed = ramp(rightDepth)
        } else {
            return stop()
        }
        start()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        onScroll = nil
        direction = 0
        speed = 0
    }

    private func ramp(_ depth: Double) -> Double {
        let ratio = min(1, max(0, depth / Self.edgeWidth))
        return Self.maxSpeed * ratio * ratio
    }

    private func start() {
        guard timer == nil else { return }
        let interval = 1.0 / 60.0
        // 心跳不许比这轮拖动活得久：三条退路各管一种死法 —— 正常松手走 stop()、
        // 视图消失/工程切走走 onDisappear、会话本身被回收就靠这里的弱引用自杀。
        // 少任何一条，RunLoop 上就可能永远留着一个 60Hz 的空转 timer。
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            MainActor.assumeIsolated { self.tick(interval: interval) }
        }
        // .common：滚动/拖动期间 runloop 会切到 tracking mode，
        // 挂在 .default 上的心跳正好在最需要它的时候停摆。
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick(interval: Double) {
        // 滚动视图没了（视图树被拆、切走工程）也算到头，别空转。
        guard scrollView != nil, onScroll != nil else { return stop() }
        guard let offset = scroll(by: direction * speed * interval) else {
            // 已经顶到头了：停掉心跳，别空转。
            stop()
            return
        }
        onScroll?(offset)
    }

    /// 推一段滚动量，返回推完的滚动位置；没能再动就返回 nil。
    private func scroll(by dx: Double) -> Double? {
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

/// 把时间线那个 `NSScrollView` 交给自动滚动用。放在滚动内容里，
/// `enclosingScrollView` 直接就是它 —— 不用像捏合那样按坐标 hitTest 去找。
struct TimelineScrollViewAccessor: NSViewRepresentable {
    let scroller: TimelineAutoScroller

    func makeNSView(context: Context) -> ScrollViewProbe {
        let view = ScrollViewProbe(frame: .zero)
        view.onAttach = { [scroller] scrollView in scroller.attach(scrollView) }
        return view
    }

    func updateNSView(_ nsView: ScrollViewProbe, context: Context) {
        nsView.onAttach = { [scroller] scrollView in scroller.attach(scrollView) }
        scroller.attach(nsView.enclosingScrollView)
    }

    /// 视图树被拆掉（切栏目、关窗）时把滚动视图撤下来，心跳跟着停。
    static func dismantleNSView(_ nsView: ScrollViewProbe, coordinator: ()) {
        nsView.onAttach?(nil)
        nsView.onAttach = nil
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
