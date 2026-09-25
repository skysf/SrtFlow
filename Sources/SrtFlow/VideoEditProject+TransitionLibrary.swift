import Foundation

/// 侧边栏转场库要作用的那个接缝。
struct TransitionSeam: Equatable {
    /// 出场段 —— 转场写在它身上（`EditClip.transitionAfter`）。
    let outgoing: EditClip
    /// 进场段，只用来取小样的首帧。
    let incoming: EditClip
}

/// 库面板这一刻有没有可下手的接缝，没有的话是因为什么 —— 面板要据此
/// 决定灰不灰、以及灰的时候说哪一句。
enum TransitionLibraryTarget: Equatable {
    case seam(TransitionSeam)
    /// 主轨不足两段，压根没有接缝。
    case noSeam
    /// 选中了不止一段。一次给一排接缝套同一个转场是另一件事，这一刀不做 ——
    /// 这时**不回退到播放头**：用户明明选了三段，转场却落在别处的接缝上，
    /// 比整块灰掉更难解释。
    case multipleSelection
    /// 候选的那条缝两边不相接 —— 中间有空隙，那不是一条缝。
    /// 空隙是用户有意留的（「留间隙剪辑」是拍过板的口径），不替他合拢。
    case notAdjacent
}

@MainActor
extension VideoEditProject {
    /// 库面板点一下卡片时作用的接缝。三级回退：
    ///
    /// ① **时间线上直接点中的那条转场** —— 意图最明确，没有比这更清楚的指认；
    /// ② **选中的那一段主轨片段**（且后面还有一段）—— 和检查器里那个入口指向
    ///    同一个接缝，两处不会给出不同答案；
    /// ③ 都没有就取**播放头最近的接缝** —— 常驻面板在没有选中时也得能用，这
    ///    正是它和检查器入口的差别（那个必须先选中才出现）。`playhead` 由面板传进来：
    ///    它用的是**停稳了的**播放头（`clock.atRest`），播放中不跟（2026-09-25 用户拍板）。
    ///
    /// 只从主轨里找：转场只有主轨有语义，上层视频轨和音频轨根本不读
    /// `transitionAfter`（见 `VideoEditCompositionBuilder` 与 `VideoEditExportGraph`
    /// 都只遍历 `state.mainClips`）。
    func transitionLibraryTarget(at playhead: Double) -> TransitionLibraryTarget {
        let clips = state.mainClips
        guard clips.count >= 2 else { return .noSeam }
        if selectedClipIDs.count > 1 { return .multipleSelection }
        let index = selectedTransitionSeamIndex(in: clips)
            ?? selectedMainSeamIndex(in: clips)
            ?? nearestSeamIndex(to: playhead, in: clips)
        // 缝找着了还不算数：两边得相接，转场才做得出来。
        // 这道闸和两条渲染管线**同一个判据**，不会出现「面板让点、成片没有」。
        // 只有「中间有空隙」是整条缝不成立。片段太短放不放得下是**逐种类**的事
        //（压黑不需要两段交叠），交给面板逐张卡片判。余料不够不再是理由：
        // 2026-09-23 起改成首尾帧定格补足（VideoEditTransitionHandles.swift）。
        if case .notAdjacent = TimelineState.transitionCapacity(
            outgoing: clips[index], incoming: clips[index + 1], kind: .crossFade
        ) { return .notAdjacent }
        return .seam(TransitionSeam(outgoing: clips[index], incoming: clips[index + 1]))
    }

    /// 时间线上**直接点中的那条转场**所在的缝。排在回退链最前面：用户明明点着
    /// 这条缝，面板却对着另一条，是最难解释的一种错。
    private func selectedTransitionSeamIndex(in clips: [EditClip]) -> Int? {
        guard let id = selection.transitionSeamID,
              let index = clips.firstIndex(where: { $0.id == id }),
              index + 1 < clips.count
        else { return nil }
        return index
    }

    /// 选中的那一段在主轨上的下标；它是最后一段（后面没有接缝）时返回 nil，
    /// 让调用方回退到播放头。
    private func selectedMainSeamIndex(in clips: [EditClip]) -> Int? {
        guard let id = selectedClipIDs.first, selectedClipIDs.count == 1 else { return nil }
        guard let location = state.location(of: id), location.track.isMain else { return nil }
        guard location.clipIndex + 1 < clips.count else { return nil }
        return location.clipIndex
    }

    /// 播放头最近的接缝。接缝取**出场段的结尾** —— 磁吸开着时它等于下一段的
    /// 开头；关着、中间留了空隙时，落在空隙里的播放头算在左边那条缝上。
    private func nearestSeamIndex(to time: Double, in clips: [EditClip]) -> Int {
        var best = 0
        var bestDistance = Double.infinity
        for index in clips.indices.dropLast() {
            let distance = abs(clips[index].timelineEnd - time)
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }

    /// 库面板点卡片：把转场套到目标接缝上。
    ///
    /// **不动时长**：已经有转场的接缝保留用户调过的秒数，第一次套上的接缝用
    /// `EditClip.transitionDuration` 的默认 0.5s。想改秒数仍然去检查器的滑块。
    ///
    /// `playhead` 必须是面板显示时用的那一个（停稳了的播放头）：播放中点卡片，套到的是面板上
    /// 那条缝、不是播放头此刻最近的那条 —— 看到哪条改哪条（2026-09-25 用户拍板）。
    func applyTransitionFromLibrary(_ transition: ClipTransition, at playhead: Double) {
        guard case .seam(let seam) = transitionLibraryTarget(at: playhead) else { return }
        applyTransition(toSeamAfter: seam.outgoing.id, transition)
    }

    /// 把一张卡落到某条缝上。**点一张卡和拖一张卡走的是这同一条路** ——
    /// 各写一遍的话，同一个动作在两个入口会给出不同结果。
    ///
    /// 时长规则见 `TimelineState.transitionDropDuration(existing:)`：空缝给默认
    /// 的 0.5s，已有转场的缝只换种类、不改时长。
    ///
    /// （改动记号：这条路以前不传 duration，于是「设过 1.2s 的转场 → 移除 → 再套
    /// 一张新卡」会悄悄沿用片段上残留的 1.2s。现在空缝一律回到 0.5s。）
    func applyTransition(toSeamAfter outgoingID: UUID, _ transition: ClipTransition) {
        guard let clip = state.clip(with: outgoingID) else { return }
        setTransition(
            after: outgoingID, transition,
            duration: TimelineState.transitionDropDuration(existing: clip)
        )
    }
}
