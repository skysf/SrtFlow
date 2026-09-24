import SwiftUI

// MARK: - 整条轨换位置：轨道头上的拖动（视图侧）
//
// 算法是纯值的 `TimelineLaneReorder`（`VideoEditTimelineLaneOrder.swift`，自检够得着）；
// 这里只有接线：起手冻结这一组、每一拍更新位移、边缘自动滚动、松手落一次。
// 长期约束见 docs/architecture/timeline-drag-gestures.md §5i；产品口径见
// docs/plans/2026-09-24-track-insert-and-reorder.md。
//
// **拖动中一个字都不写 `TimelineState`**（§0）：被拖的那条轨、让位的那几条轨画在哪，
// 只由 `LaneReorderSession` 决定；松手才 `moveLane` 一次，一步撤销。

/// 轨道头这一行能不能拖着换位置；能的话，它在哪一组、这一组有哪些行（显示顺序）。
///
/// 由轨道头列按 `rows` 算好传给每一行。**是值、可比较**：轨道头的行在时钟每跳一下时
/// 不重算，靠的就是它的输入每次都「相等」（docs/architecture/preview-perf-ratchet.md）——
/// 往这里塞闭包的话，每跳一下整列行都会跟着重算。
struct LaneReorderContext: Equatable {
    var group: TimelineLaneGroup
    /// 这一组的行（`RowSpec.id`），显示顺序（从上往下）。
    var rowIDs: [String]
    var heights: [Double]
    /// 这一行在这一组里的显示下标。
    var displayIndex: Int

    /// 每一行的换位上下文，按行 id 查。
    ///
    /// 主轨、非轨道行没有（主轨永远是最底层画面）；这一组只有一条轨时也没有 —— 没什么
    /// 可换的，也就不显示抓手。
    static func make(for rows: [VideoEditTimelineView.RowSpec]) -> [String: LaneReorderContext] {
        var result: [String: LaneReorderContext] = [:]
        for group in [TimelineLaneGroup.overlay, .audio] {
            let members = rows.filter { TimelineLaneGroup($0.slot) == group }
            guard members.count > 1 else { continue }
            for (index, row) in members.enumerated() {
                result[row.id] = LaneReorderContext(
                    group: group,
                    rowIDs: members.map(\.id),
                    heights: members.map(\.height),
                    displayIndex: index
                )
            }
        }
        return result
    }
}

/// 一轮整轨拖动。**只是视图状态**，松手才落进模型。
struct LaneReorderSession: Equatable {
    /// 其余行让位的动画。被拖的那一行自己不动画（`laneReorderOffset`，§2 第 1 条）。
    static let animation = Animation.easeOut(duration: 0.15)

    /// 起手时冻结的这一组。
    var context: LaneReorderContext
    /// 被拖的那一行。
    var rowID: String
    /// 手势起点。`onEnded` 不保证会来（模态挡在前面、窗口失活）：起点变了就是新的一轮，
    /// 不接着用残留的会话。
    var startY: Double
    /// 起手时的纵向滚动量（现读，§5b）。
    var originScrollY: Double
    /// 指针走了多远（手势坐标系钉在不动的轨道头列上）。
    var translation = 0.0
    /// 纵向自动滚动推走了多少：指针不动、内容在滚，被拖的那条轨也要跟着指针。
    var scrolled = 0.0

    var resolution: TimelineLaneReorder.Resolution {
        TimelineLaneReorder.resolve(
            heights: context.heights,
            dragged: context.displayIndex,
            offset: translation + scrolled
        )
    }

    /// 某一行此刻的纵向位移（不在这一组的行是 0）。
    func offset(forRow id: String) -> Double {
        guard let index = context.rowIDs.firstIndex(of: id) else { return 0 }
        let resolution = resolution
        if index == context.displayIndex { return resolution.draggedOffset }
        return resolution.offsets.indices.contains(index) ? resolution.offsets[index] : 0
    }

    /// 松手时在数组里从哪个下标挪到哪个下标（上层轨的行是倒着排的）。
    var arrayMove: (from: Int, to: Int) {
        let count = context.rowIDs.count
        return (
            context.group.arrayIndex(displayIndex: context.displayIndex, count: count),
            context.group.arrayIndex(displayIndex: resolution.destination, count: count)
        )
    }
}

extension View {
    /// 整轨换位时这一行画在哪：被拖的那一行跟着指针走（不带动画、压在别的行上面），
    /// 其余行按会话给的位移让开（动画由落点变了的那一拍的 `withAnimation` 给）。
    ///
    /// 轨道头列和轨道行都挂这**一个**，两边才永远对得上。是函数不是修饰器：只用
    /// `.offset` / `.zIndex` / `.transaction` 这类不计数的原语，平时位移全是 0，
    /// 时钟每跳一下不多一次重算（preview-perf-ratchet.md）。
    func laneReorderOffset(_ session: LaneReorderSession?, rowID: String) -> some View {
        let dragged = session?.rowID == rowID
        return offset(y: session?.offset(forRow: rowID) ?? 0)
            .zIndex(dragged ? 1 : 0)
            .transaction { transaction in
                if dragged { transaction.animation = nil }
            }
    }
}

@MainActor
extension VideoEditProject {
    /// 整条轨换位置（轨道头拖动松手）。一步撤销；上层轨换了叠放顺序，`perform` 会
    /// 重建预览。挪到原位什么都不做（不进撤销栈）。
    func moveLane(_ group: TimelineLaneGroup, from: Int, to: Int) {
        guard from != to else { return }
        perform { $0.moveLane(group, from: from, to: to) }
    }
}
