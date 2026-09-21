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
        case text
        case subtitleCue
        case filter
    }

    let subject: Subject
    /// 手势开始时冻结的全部输入。
    let plan: ClipDragPlan
    /// 手势开始时的横向滚动量：边缘自动滚动把内容抽走时要补回来。
    let originScrollOffset: Double
    /// 手势开始时的纵向滚动量：跨轨判定要按「此刻露出来的是哪几条轨」算，
    /// 纵向自动滚动期间指针不动、内容在滚，差的就是这一段。
    let originScrollOffsetY: Double

    /// 最近一次手势位移。自动滚动那一拍指针根本没动，得靠它重算落点。
    private(set) var translation: CGSize = .zero
    /// 这一拍的落点解析（位移 / 对齐线 / 磁吸插入位置）。
    private(set) var resolution: DragResolution

    init(
        subject: Subject,
        plan: ClipDragPlan,
        originScrollOffset: Double,
        originScrollOffsetY: Double
    ) {
        self.subject = subject
        self.plan = plan
        self.originScrollOffset = originScrollOffset
        self.originScrollOffsetY = originScrollOffsetY
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
    /// 磁吸主轨松手会插进的时间段（占位框画这里；自由落点轨为 nil）。
    /// 宽度也来自 `TimelineSnap.mainInsertion` —— 框有多长，落地就占多长。
    var mainInsertionSpan: TimelineSpan? {
        guard let insertion = resolution.mainInsertion else { return nil }
        return TimelineSpan(start: insertion.time, end: insertion.time + insertion.duration)
    }
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
    /// 纵向的边缘带要窄一些：时间线本来就不高，44 上下一夹中间没剩多少。
    static let edgeHeight: Double = 26
    /// 完全贴边时的速度（点/秒）。中间按penetration平方渐进，刚进边缘时很慢。
    static let maxSpeed: Double = 900

    /// 推滚动量这件事本身归 `TimelineScrollGeometry`（整个时间线只有它碰
    /// `NSScrollView`）；这里只管心跳。
    private var geometry: TimelineScrollGeometry?
    private var timer: Timer?
    /// 这一拍要往哪个方向、以多快推（点/秒）。两轴各算各的。
    private var velocity: CGVector = .zero
    private var onScroll: (() -> Void)?

    func attach(_ geometry: TimelineScrollGeometry?) {
        self.geometry = geometry
        if geometry == nil { stop() }
    }

    deinit {
        // deinit 可能不在主线程：只 invalidate 已调度的 timer，不碰别的状态。
        timer?.invalidate()
    }

    /// 每次拖动回调都调一次。`pointer` 是指针在**可见视口**里的位置。
    /// 进边缘就开始滚，离开边缘就停；滚过之后回调一次，调用方自己去
    /// `TimelineScrollGeometry` 现读新的滚动量重算落点 —— 心跳不传这个数，
    /// 传了就等于又多出一个「滚动量的来源」。
    ///
    /// 两轴各算各的：轨道多到一屏放不下时，把块拖去下面那条看不见的轨，
    /// 全靠纵向这一半（2026-09-18）。
    func update(pointer: CGPoint, viewport: CGSize, onScroll: @escaping () -> Void) {
        self.onScroll = onScroll
        var next = CGVector.zero
        if viewport.width > Self.edgeWidth * 2 {
            let leftDepth = Self.edgeWidth - pointer.x
            let rightDepth = pointer.x - (viewport.width - Self.edgeWidth)
            if leftDepth > 0 {
                next.dx = -ramp(leftDepth, edge: Self.edgeWidth)
            } else if rightDepth > 0 {
                next.dx = ramp(rightDepth, edge: Self.edgeWidth)
            }
        }
        if viewport.height > Self.edgeHeight * 2 {
            let topDepth = Self.edgeHeight - pointer.y
            let bottomDepth = pointer.y - (viewport.height - Self.edgeHeight)
            if topDepth > 0 {
                next.dy = -ramp(topDepth, edge: Self.edgeHeight)
            } else if bottomDepth > 0 {
                next.dy = ramp(bottomDepth, edge: Self.edgeHeight)
            }
        }
        guard next.dx != 0 || next.dy != 0 else { return stop() }
        velocity = next
        start()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        onScroll = nil
        velocity = .zero
    }

    private func ramp(_ depth: Double, edge: Double) -> Double {
        let ratio = min(1, max(0, depth / edge))
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
        guard let geometry, geometry.isAttached, onScroll != nil else { return stop() }
        let movedX = velocity.dx != 0
            && geometry.scrollHorizontally(by: velocity.dx * interval) != nil
        let movedY = velocity.dy != 0
            && geometry.scrollVertically(by: velocity.dy * interval) != nil
        // 两轴都推不动了（顶到头）才停，否则会在只剩一个方向能滚时误停。
        guard movedX || movedY else {
            stop()
            return
        }
        onScroll?()
    }
}
