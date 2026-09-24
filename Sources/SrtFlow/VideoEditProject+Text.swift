import CoreGraphics
import Foundation
import SrtFlowCore

// 文字标注的生产入口：加 / 改 / 删 / 拖时间。
//
// 全部走 `perform(rebuildsPreview: false)` —— 文字和形状一样是**叠层**，
// 不进 AVComposition，重建一次预览换来画面一帧不变，还会让画面黑一下。
//
// 长期约束见 docs/architecture/text-overlays.md。
@MainActor
extension VideoEditProject {

    // MARK: - 增删

    /// 在播放头处放一段空文字，选中它并请求就地编辑。
    ///
    /// 新建的是**空文字**而不是"双击编辑"之类的占位串：占位串一旦被用户留在
    /// 那儿没删，就会原样烧进成片。空文字在画面上什么都不画，只有选中框在，
    /// 配合自动进入的就地编辑，用户下一个动作自然就是打字。
    func addTextOverlay() {
        var overlay = TextOverlay(timelineStart: clock.time)
        // 永远在最上面新开一行（2026-09-24 用户拍板）：新字压在所有旧字之上。
        perform(rebuildsPreview: false) { state in
            overlay.row = state.textRowCount
            state.textOverlays.append(overlay)
        }
        selectedTextIDs = [overlay.id]
        // 视图层看到它变化就把输入框浮出来（见 VideoEditTextInlineEditor）。
        textEditingRequest = overlay.id
    }

    /// 在播放头处放一个数字元件。
    ///
    /// 不进就地编辑 —— 数字没有"打字"这一步，内容全在检查器里调。
    /// 默认时长比普通文字长：滚 1.5 秒之后还得让人看清最终那个数。
    func addNumberOverlay() {
        var overlay = TextOverlay(timelineStart: clock.time, duration: 4)
        overlay.number = .default
        perform(rebuildsPreview: false) { state in
            overlay.row = state.textRowCount
            state.textOverlays.append(overlay)
        }
        selectedTextIDs = [overlay.id]
    }

    func deleteTextOverlay(_ id: UUID) {
        perform(rebuildsPreview: false) { state in
            state.textOverlays.removeAll { $0.id == id }
            state.compactTextRows()
        }
        pruneTextSelection(removing: id)
    }

    /// 文字不参与 AV 合成，改它不用重建预览。
    func updateTextOverlay(_ id: UUID, _ change: @escaping (inout TextOverlay) -> Void) {
        perform(rebuildsPreview: false) { $0.updateTextOverlay(id, change) }
    }

    /// 拖动中的实时版本（不进撤销栈，松手时由 `endLiveEdit` 收一次）。
    func liveUpdateTextOverlay(_ id: UUID, _ change: @escaping (inout TextOverlay) -> Void) {
        liveApply { $0.updateTextOverlay(id, change) }
    }

    // MARK: - 时间线上的拖动

    /// 拖文字块两端裁切（实时版本）。`deltaSeconds` 是手势开始以来的总位移。
    ///
    /// 与形状同一套口径：没有素材边界，起点端最多回拉到 0，两端收缩的下限是
    /// `TextOverlay.minimumDuration`。
    func liveTrimTextOverlay(_ id: UUID, leading: Bool, deltaSeconds: Double) {
        beginLiveEdit()
        liveApply { state in
            state.updateTextOverlay(id) { overlay in
                let minDuration = TextOverlay.minimumDuration
                if leading {
                    let delta = min(max(deltaSeconds, -overlay.timelineStart), overlay.duration - minDuration)
                    overlay.timelineStart += delta
                    overlay.duration -= delta
                } else {
                    overlay.duration += max(deltaSeconds, -(overlay.duration - minDuration))
                }
            }
        }
    }

    // MARK: - 查询

    /// 此刻画面上该显示的文字，**按叠放次序**（行号大的靠后、画在上面；导出同一份序）。
    ///
    /// 空文字留在结果里：它虽然不渲染画面，但选中框要画得出来 ——
    /// 刚 Add 出来还没打字的那一段全靠它才点得着。
    func visibleTextOverlays(at time: Double) -> [TextOverlay] {
        state.textOverlaysInStackingOrder.filter { $0.contains(time: time) }
    }

    /// 文字块的拖动会话。与形状那条**逐字同构** —— 文字自己没有障碍：横向落点被同一行
    /// 的别的字占着时，松手往上找空行（`TimelineState.settleTextRow`），不是挡住不许动；
    /// 跟着走的剪辑各自带上本轨的障碍。
    func textDragPlan(textID id: UUID) -> ClipDragPlan? {
        guard let overlay = state.textOverlays.first(where: { $0.id == id }) else { return nil }
        let span = TimelineSpan(start: overlay.timelineStart, end: overlay.timelineEnd)
        let clipIDs = state.draggingClipIDs(
            seed: selectedTextIDs.contains(id) ? selectedClipIDs : [],
            linkage: linkageEnabled,
            magnetPinsMainTrack: magnetEnabled
        )
        let companions = movingCompanions(draggedID: id, movingClipIDs: clipIDs)
        let members = [ClipDragPlan.Member(id: id, span: span, obstacles: [], kind: .text)]
            + ClipDragPlan.clipMembers(in: state, movingIDs: clipIDs)
        return ClipDragPlan(
            draggedID: id,
            draggedSpan: span,
            members: members,
            candidates: snapCandidates(moving: clipIDs.union(companions.ids).union([id])),
            magnet: nil
        ).adding(shapes: companions.shapes, texts: companions.texts, cues: companions.cues)
    }
}
