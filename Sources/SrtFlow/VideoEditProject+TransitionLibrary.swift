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
}

@MainActor
extension VideoEditProject {
    /// 库面板点一下卡片时作用的接缝。两级回退：
    ///
    /// ① **选中的那一段主轨片段**（且后面还有一段）—— 意图最明确，而且和检查
    ///    器里那个入口指向同一个接缝，两处不会给出不同答案；
    /// ② 没选中就取**播放头最近的接缝** —— 常驻面板在没有选中时也得能用，这
    ///    正是它和检查器入口的差别（那个必须先选中片段才出现）。
    ///
    /// 只从主轨里找：转场只有主轨有语义，上层视频轨和音频轨根本不读
    /// `transitionAfter`（见 `VideoEditCompositionBuilder` 与 `VideoEditExportGraph`
    /// 都只遍历 `state.mainClips`）。
    var transitionLibraryTarget: TransitionLibraryTarget {
        let clips = state.mainClips
        guard clips.count >= 2 else { return .noSeam }
        if selectedClipIDs.count > 1 { return .multipleSelection }
        let index = selectedMainSeamIndex(in: clips) ?? nearestSeamIndex(to: clock.time, in: clips)
        return .seam(TransitionSeam(outgoing: clips[index], incoming: clips[index + 1]))
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
    func applyTransitionFromLibrary(_ transition: ClipTransition) {
        guard case .seam(let seam) = transitionLibraryTarget else { return }
        setTransition(after: seam.outgoing.id, transition)
    }
}
