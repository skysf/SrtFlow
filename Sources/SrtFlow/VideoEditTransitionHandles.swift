import Foundation

/// 一条主轨接缝能不能放转场、最多能放多长。
///
/// 转场要两段**同时**出现在画面上，而这个编辑器**不挪用户摆好的片段**
/// （位置是用户的意图，2026-09-20 用户拍板）。两段只是首尾相接时，接缝左边
/// 只有出场段、右边只有进场段 —— 唯一的出路是向两边借**被裁掉的素材**：出场
/// 段用它尾巴上没用到的部分，进场段用它头上没用到的部分，转场以接缝为中心各
/// 向外吃一半。Premiere 和达芬奇管这叫 handles，余量不够时同样是拒绝。
///
/// 这么做的账：总时长不变、片段位置不动，而展开之后两段**真的相叠 d**，
/// 于是导出的 xfade 链和预览的淡变逻辑原样成立（见 `expandingTransitionHandles`）。
enum TransitionCapacity: Equatable {
    /// 能放，最长这么久（时间线秒）。
    case available(maxDuration: Double)
    /// 两段之间有空隙 —— 那不是一条接缝。
    case notAdjacent
    /// 首尾相接，但至少一边没有多余素材可借。
    case noHandles
}

extension EditClip {
    /// 尾巴上还没用到的素材，换算成**时间线秒**（除过变速）。
    var trailingHandle: Double {
        max(0, assetDuration - (sourceStart + sourceDuration)) / max(0.05, speed)
    }

    /// 头上还没用到的素材，换算成**时间线秒**。
    var leadingHandle: Double {
        max(0, sourceStart) / max(0.05, speed)
    }
}

extension TimelineState {
    /// 产品上限：再长就不像转场了，而且检查器那个滑块也是按这个刻度画的。
    static let transitionMaxDuration = 2.0

    /// 相接判据的容差。和导出分节里那个判据用**同一个数** —— 两处分头写的话
    /// 迟早一处认这是接缝、另一处不认。
    static let seamTolerance = 0.02

    /// 第 index 段和下一段之间这条缝的容量。
    func transitionCapacity(afterMainIndex index: Int) -> TransitionCapacity {
        guard index >= 0, index + 1 < mainClips.count else { return .notAdjacent }
        return Self.transitionCapacity(outgoing: mainClips[index], incoming: mainClips[index + 1])
    }

    /// 两种几何都要认，判据就是当下这两段的相对位置：
    ///
    /// - **已相叠**（磁吸开着，`packMain` 就是这么排的）：转场吃的是片段自己的
    ///   时间，几何跟着时长走（改时长会重新 pack），所以容量按老规矩 —— 较短
    ///   那段的 45%。这条路**不借余料、不展开**，行为和 0.9.x 一模一样。
    /// - **首尾相接**（磁吸关着，默认）：片段位置是用户的意图，不能挪。转场只能
    ///   向两边借裁掉的素材，容量就是余料说了算。
    ///
    /// 中间有空隙的不是缝 —— 空隙是用户有意留的，不替他合拢。
    static func transitionCapacity(outgoing: EditClip, incoming: EditClip) -> TransitionCapacity {
        let gap = incoming.timelineStart - outgoing.timelineEnd
        if gap > seamTolerance { return .notAdjacent }
        let byLength = min(outgoing.timelineDuration, incoming.timelineDuration)
        if gap < -seamTolerance {
            // 已相叠：老规矩，和 `transitionOverlap` 那条 45% 护栏同一个数。
            return .available(maxDuration: min(byLength * 0.45, transitionMaxDuration))
        }
        // 相接：借余料。两边各要 d/2。
        let halfByHandles = min(outgoing.trailingHandle, incoming.leadingHandle)
        // 半秒的一成：比这还少借不出一帧像样的转场，当没有余料。
        guard halfByHandles > 0.05 else { return .noHandles }
        // 「最多吃掉较短那段的一半」。这个上限不是随手定的：展开之后两段各长
        // d/2，而 `transitionOverlap` 那条 45% 的护栏是按**展开后**的长度算的，
        // d ≤ 0.5·min(a,b) 正好让它不咬人（0.45·(a+d/2) ≥ 0.5625a > 0.5a）。
        // 松过这个数，护栏就会把实际叠掉的量压到 d 以下，展开时按 d/2 让出去的
        // 长度收不回来，成片会比时间线长出一截。
        let half = min(halfByHandles, byLength * 0.25, transitionMaxDuration / 2)
        guard half > 0.05 else { return .noHandles }
        return .available(maxDuration: half * 2)
    }

    /// 这条缝当下是不是**首尾相接**（需要借余料），而不是已经相叠。
    static func needsHandles(outgoing: EditClip, incoming: EditClip) -> Bool {
        abs(incoming.timelineStart - outgoing.timelineEnd) < seamTolerance
    }

    /// 这条缝上**实际**成立的转场时长：用户设的值被容量夹住；缝不成立就是 0。
    func effectiveTransitionDuration(afterMainIndex index: Int) -> Double {
        guard index >= 0, index + 1 < mainClips.count else { return 0 }
        guard mainClips[index].transitionAfter != .none else { return 0 }
        guard case .available(let maxDuration) = transitionCapacity(afterMainIndex: index) else {
            return 0
        }
        return min(mainClips[index].transitionDuration, maxDuration)
    }

    /// 把接缝两侧的片段各向外借 d/2 的余料，让它们**真的相叠 d**。
    ///
    /// 两条渲染管线（预览合成、导出图）都在入口处调这一份，之后它们看到的就是
    /// 一份「相叠」的时间线 —— 原来那套按相叠写的 xfade 链和淡变逻辑一行都不用
    /// 改。总账：出场段尾部 +d/2、进场段头部 -d/2 且时长 +d/2，拼接时叠掉 d，
    /// 加加减减之后总长与展开前**一模一样**，片段在用户眼里也没动过。
    ///
    /// 只动主轨：转场只有主轨有语义。缝不成立（有空隙、或余料不够）的，
    /// 顺手把 `transitionAfter` 清成 `.none` —— 与其让下游各自再判一次，不如在
    /// 这里就把不成立的转场从渲染用的副本里摘掉（**不写回用户的工程**）。
    func expandingTransitionHandles() -> TimelineState {
        guard mainClips.count >= 2 else { return self }
        var expanded = self
        // 先把每条缝的实际时长算出来：下面会改 mainClips，边改边算会拿到改过的
        // 长度和起点，缝与缝之间互相污染。
        // 只有「首尾相接」的缝要展开；已相叠的（磁吸排的）几何已经成立，
        // 碰它反而会把叠量加倍。
        let durations = (0..<(mainClips.count - 1)).map { index -> Double in
            guard Self.needsHandles(outgoing: mainClips[index], incoming: mainClips[index + 1])
            else { return 0 }
            return effectiveTransitionDuration(afterMainIndex: index)
        }
        for index in mainClips.indices {
            let after = index < durations.count ? durations[index] : 0
            let before = index > 0 ? durations[index - 1] : 0
            // 缝根本不成立（有空隙 / 余料不够）的，把转场从**渲染用的副本**里
            // 摘掉，别让下游各自再判一次。已相叠的缝 after 是 0 但缝是成立的，
            // 不能连它一起摘 —— 用 capacity 判，不是用 after 判。
            if case .available = transitionCapacity(afterMainIndex: index) {} else {
                expanded.mainClips[index].transitionAfter = .none
            }
            if after > 0 {
                expanded.mainClips[index].transitionDuration = after
                // 尾巴借 after/2：素材秒 = 时间线秒 × 变速。
                expanded.mainClips[index].sourceDuration += after / 2 * expanded.mainClips[index].speed
            }
            if before > 0 {
                // 头部前移 before/2，起点跟着往前挪同样多 —— 片段在时间线上的
                // **可见**位置没变，变的是它多带了一段用来做转场的引子。
                expanded.mainClips[index].sourceStart -= before / 2 * expanded.mainClips[index].speed
                expanded.mainClips[index].sourceDuration += before / 2 * expanded.mainClips[index].speed
                expanded.mainClips[index].timelineStart -= before / 2
            }
        }
        return expanded
    }
}
