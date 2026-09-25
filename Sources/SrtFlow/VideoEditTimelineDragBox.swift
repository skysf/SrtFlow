import Combine
import Foundation

// MARK: - 拖动会话的盒子：时间线拿着、不订阅，块和覆盖层各订阅自己那一份
//
// 管什么：一轮拖动 / 拉框**进行中**的全部视图状态 —— 块拖动会话（`ClipDragSession`）、拉框
// 会话（`TimelineMarquee.Session`）、纵向瞄准的目标行、文字块的目标行、cue 起手的记号 ——
// 以及它们往外发的两份「订阅用」的值（`offsets`、`marqueeHit`）。
// 不管什么：手势怎么接（`VideoEditTimelineDragWiring.swift` / `VideoEditTimelineMarqueeGesture.swift`）、
// 落点怎么算（`ClipDragPlan.resolve`）、松手怎么落地（`VideoEditProject.commitDrag`）。
//
// 为什么是引用类型、为什么时间线不订阅（docs/architecture/timeline-drag-gestures.md §0b）：
// 2026-09-25 之前这些都是 `VideoEditTimelineView` 的 `@State`，拖动每一拍写一次，时间线的 body
// 就整个重算一次 —— 块靠 `.equatable()` 挡住了自己的 body，但 ForEach 的 diff、AttributeGraph 的
// 更新和布局挡不住，采样里占拖动中主线程约 75%（用户工程上一拍 20–40ms）。搬进这个盒子之后，
// 时间线用 `@State` **持有**它但一个字都不读（和 `TimelineScrollGeometry` 完全同一个模式）；
// 每一拍变的只有：正在动的那几个块（`onReceive(box.$offsets)` 收到自己的位移才写自己的 @State）
// 和几张覆盖层（`TimelineDragOverlay`，`@ObservedObject` 这个盒子）。

/// 块们订阅的那一份：谁在动、动了多少。`Equatable`，盒子只在变了时才发。
struct DragOffsets: Equatable {
    /// 跟着一起动的块（含被拖的那个）。会话开始时从冻结的计划算一次。
    var movingIDs: Set<UUID> = []
    /// 整组共用的位移（秒）。
    var offset: Double = 0
    var isActive = false

    /// 这个块此刻的渲染位移；nil = 没在被拖，按模型里的位置画。
    func offset(for id: UUID) -> Double? {
        isActive && movingIDs.contains(id) ? offset : nil
    }
}

/// 垂直拖动瞄准的目标行（高亮它）。落进拉开的缝时 id 是 "seam"。
struct DragRowTarget: Equatable {
    var id: String
    var target: TrackDropTarget
}

/// 一轮拖动 / 拉框进行中的视图状态。时间线用 `@State` 持有、**不订阅**。
@MainActor
final class TimelineDragBox: ObservableObject {
    /// 正在进行的块拖动。**拖动中不写 `TimelineState`**：块画在哪只由它的 `offset` 决定，
    /// 松手才 `commitDrag` / `commitFreeDrag` 落一次（§0）。
    @Published private(set) var clipDrag: ClipDragSession?
    /// 块订阅的位移（只在变了时发）。块不直接订阅它，走 `offsets(member:)`。
    @Published private(set) var offsets = DragOffsets()
    /// 永远不发的发布者：不是这一轮成员的块订阅它。
    private static let silence = Empty<DragOffsets, Never>(completeImmediately: false).eraseToAnyPublisher()
    /// 正在拉的选择框。同一条约束：**拖框中不写 `project`**，高亮谁只由它的 `hit` 决定，
    /// 松手才 `applyBoxSelection` 落一次。
    @Published private(set) var marquee: TimelineMarquee.Session?
    /// 块订阅的框选命中（只在变了时发）。nil = 没在拉框，块按模型里的选中画。
    @Published private(set) var marqueeHit: TimelineMarquee.Hit?
    /// 垂直拖动瞄准的目标行。写入时比过再发：每一拍都写但很少变。
    @Published private(set) var dragTargetRow: DragRowTarget?
    /// 拖文字块时的目标行（`textRowCount` = 顶上新开一行）。只是视图状态，松手才写模型。
    @Published private(set) var textDropRow: Int?
    /// 正在被拖的字幕 cue。剪辑 / 形状块各自是独立视图、用自己的 `isMoving` 标记起手，
    /// cue 块的起手判据在行里，只能在这一层按 id 记。不发通知：只在手势回调里读。
    var movingCueID: UUID?

    // MARK: 块拖动

    /// 给块订阅的位移。**只有这一轮的成员真的订阅**（`member` 由时间线按 `dragMembers` 算好传给块）：
    /// 150 个块都订阅的话，每一拍发一次位移，SwiftUI 就把 150 个 `onReceive` 节点各标脏一遍、沿祖先链
    /// 各传一遍 —— 2026-09-25 采样里 `AG::Graph::propagate_dirty` 占拖动中主线程约三分之一，块自己的
    /// 闭包倒是便宜。不是成员的块拿到一个永远不发的发布者。
    func offsets(member: Bool) -> AnyPublisher<DragOffsets, Never> {
        member ? $offsets.eraseToAnyPublisher() : Self.silence
    }

    func begin(_ session: ClipDragSession) {
        clipDrag = session
        offsets = DragOffsets(movingIDs: session.movingIDs, offset: session.offset, isActive: true)
    }

    /// 每一拍：会话换成新的解析结果；块们只在位移真变了时才被叫醒。
    func update(_ session: ClipDragSession) {
        clipDrag = session
        if offsets.offset != session.offset {
            offsets.offset = session.offset
        }
    }

    func aim(row: DragRowTarget?) {
        if dragTargetRow != row { dragTargetRow = row }
    }

    func aim(textRow: Int?) {
        if textDropRow != textRow { textDropRow = textRow }
    }

    /// 松手 / 视图消失：这一轮的一切都收掉（块的位移回 nil，目标行、文字行、cue 记号一起清）。
    func end() {
        clipDrag = nil
        if offsets != DragOffsets() { offsets = DragOffsets() }
        if dragTargetRow != nil { dragTargetRow = nil }
        if textDropRow != nil { textDropRow = nil }
        movingCueID = nil
    }

    // MARK: 拉框

    func beginMarquee(_ session: TimelineMarquee.Session) {
        marquee = session
        marqueeHit = session.hit
    }

    func updateMarquee(_ session: TimelineMarquee.Session) {
        marquee = session
        if marqueeHit != session.hit { marqueeHit = session.hit }
    }

    func endMarquee() {
        marquee = nil
        if marqueeHit != nil { marqueeHit = nil }
    }

    /// 视图消失：两种会话都清。
    func reset() {
        end()
        endMarquee()
    }
}
