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
    ///
    /// `kind` 不传就按这条缝**当前**设的那种算。容量**与种类有关** —— 压黑不
    /// 需要两段同时在画面上（见 `rendersAsDipInPlace`），所以零余料的缝上它
    /// 能用、叠化不能用。库面板据此逐张卡片判定可用，不是整块灰。
    func transitionCapacity(afterMainIndex index: Int, kind: ClipTransition? = nil) -> TransitionCapacity {
        guard index >= 0, index + 1 < mainClips.count else { return .notAdjacent }
        return Self.transitionCapacity(
            outgoing: mainClips[index],
            incoming: mainClips[index + 1],
            kind: kind ?? mainClips[index].transitionAfter
        )
    }

    /// 这种转场能不能**只靠两段自己现有的内容**做出来（不需要同时在画面上）。
    ///
    /// 压黑就是「A 灭到黑、B 从黑亮起」，两段各自做一道 alpha 斜坡就够了 ——
    /// 主轨片段底下垫的正是黑底，`VideoFade` 那条斜坡出来的**就是**压黑。
    /// 不借料、不丢内容、长度天然不变。
    ///
    /// 闪白不行：现有机制垫的是黑底，淡向白色要另铺一层白的。
    /// 叠化、推移、擦除都要两段同时出现在画面上，更不行。
    static func rendersAsDipInPlace(_ kind: ClipTransition) -> Bool {
        kind == .blackFade
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
    static func transitionCapacity(
        outgoing: EditClip, incoming: EditClip, kind: ClipTransition
    ) -> TransitionCapacity {
        let gap = incoming.timelineStart - outgoing.timelineEnd
        if gap > seamTolerance { return .notAdjacent }
        let byLength = min(outgoing.timelineDuration, incoming.timelineDuration)
        // 「取消转场」在哪条缝上都得能做。
        if kind == .none { return .available(maxDuration: transitionMaxDuration) }
        if gap < -seamTolerance {
            // 已相叠：老规矩，和 `transitionOverlap` 那条 45% 护栏同一个数。
            return .available(maxDuration: min(byLength * 0.45, transitionMaxDuration))
        }
        // 相接 + 压黑：走原地斜坡，一点余料都不用（见 rendersAsDipInPlace）。
        if rendersAsDipInPlace(kind) {
            return .available(maxDuration: min(byLength * 0.4, transitionMaxDuration))
        }
        // 相接 + 其余种类：借余料。
        //
        // **窗口不必对称**。只有出场段有尾料时，把窗口整个放在接缝**之后**照样
        // 成立：进场段在那段时间本来就在播它自己的开头，出场段拿尾料叠在上面
        // 淡出 —— 一个完完整整的交叉淡变，两边的可见内容一帧都没少。反过来
        // 只有进场段有头料时同理，窗口整个落在接缝之前。
        // 所以容量是**两边余料之和**，不是 2×min（按 min 算会把单边有料的缝
        // 白白判死，那正是 2026-09-20 第一版的毛病）。
        let borrowable = outgoing.trailingHandle + incoming.leadingHandle
        // 半秒的一成：比这还少借不出一帧像样的转场，当没有余料。
        guard borrowable > 0.05 else { return .noHandles }
        // 长度上限：展开之后 `transitionOverlap` 那条 45% 的护栏会按**展开后**
        // 的长度再夹一次 d，夹到了就说明实际叠掉的量 < d，而展开时已经按 d 让
        // 出去了长度 —— 收不回来，成片会比时间线长出一截。
        //
        // 要让护栏夹不动，得 d ≤ 0.45·a' 且 d ≤ 0.45·b'（a'、b' 是展开后的长度）。
        // 最坏情况是 d 全从一边借：全借尾料时 a' = a + d、b' = b，b 那边没长，
        // 于是 d ≤ 0.45·b 是紧的那道；全借头料时对称地变成 d ≤ 0.45·a。
        // 两种都要满足 ⇒ d ≤ 0.45·min(a, b)。取 0.4 留一点余量。
        let capped = min(borrowable, byLength * 0.4, transitionMaxDuration)
        guard capped > 0.05 else { return .noHandles }
        return .available(maxDuration: capped)
    }

    /// 这条缝上 d 秒的转场，各从哪一边借多少。先吃出场段的尾料，不够再找进场
    /// 段借头料 —— 窗口因此可能整个落在接缝一侧，那是成立的（见上面的说明）。
    static func borrowSplit(
        outgoing: EditClip, incoming: EditClip, duration: Double
    ) -> (fromTail: Double, fromHead: Double) {
        let tail = min(outgoing.trailingHandle, duration)
        let head = min(incoming.leadingHandle, duration - tail)
        return (tail, head)
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

    /// 这条缝上的转场在**时间线上**占的那一段 —— 时间线的转场遮罩就画在这儿。
    /// 没有转场、或者这条缝做不出转场，返回 nil。
    ///
    /// 两种几何两种算法：
    /// - **已相叠**（磁吸排的）：转场就发生在两段重叠的那一段上，窗口即重叠区。
    /// - **首尾相接**：转场跨在缝上，两边各一半 —— 借余料那条路是各借 d/2，
    ///   压黑那条路是各做 d/2 的渐变，两者的窗口一模一样。
    func transitionWindow(afterMainIndex index: Int) -> (start: Double, duration: Double)? {
        guard index >= 0, index + 1 < mainClips.count else { return nil }
        let outgoing = mainClips[index]
        let incoming = mainClips[index + 1]
        guard outgoing.transitionAfter != .none else { return nil }
        guard case .available(let maxDuration) = transitionCapacity(afterMainIndex: index) else {
            return nil
        }
        if Self.needsHandles(outgoing: outgoing, incoming: incoming) {
            let d = min(outgoing.transitionDuration, maxDuration)
            guard d > 0.01 else { return nil }
            return (outgoing.timelineEnd - d / 2, d)
        }
        let overlap = outgoing.timelineEnd - incoming.timelineStart
        guard overlap > 0.01 else { return nil }
        return (incoming.timelineStart, overlap)
    }

    /// 遮罩在时间线上画出来的矩形（`x` 是左边界，单位 pt）。
    ///
    /// **宽度有下限，位置就必须跟着补偿**：窄到贴下限时如果还把左边界钉在
    /// `window.start`，下限多出来的那几个 pt 全长在右边 —— 转场越短偏得越厉害，
    /// 用户拖短它的时候看见的就是「遮罩整个往右挪」（2026-09-20 用户报的正是
    /// 这个）。所以按**窗口中心**摆，宽度怎么被夹都不影响它对准缝。
    static func transitionMaskRect(
        window: (start: Double, duration: Double), pps: Double, minWidth: Double
    ) -> (x: Double, width: Double) {
        let width = max(minWidth, window.duration * pps)
        let center = (window.start + window.duration / 2) * pps
        return (center - width / 2, width)
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
            // 压黑不走借料这条路（下面单独改写），这里当它不需要展开。
            guard !Self.rendersAsDipInPlace(mainClips[index].transitionAfter) else { return 0 }
            return effectiveTransitionDuration(afterMainIndex: index)
        }
        // 压黑走的是另一条路：不借料、不相叠，改写成两段各自的头尾渐变。
        // 主轨片段底下垫的就是黑底，一道 alpha 斜坡出来**就是**压黑
        //（VideoEditVideoFade.swift 开头讲了为什么不能写成显式淡向黑色）。
        // 只对「首尾相接」的缝这么办；已相叠的（磁吸排的）照旧走 xfade。
        for index in 0..<(mainClips.count - 1) {
            guard Self.needsHandles(outgoing: mainClips[index], incoming: mainClips[index + 1]),
                  Self.rendersAsDipInPlace(mainClips[index].transitionAfter),
                  case .available(let maxDuration) = transitionCapacity(afterMainIndex: index)
            else { continue }
            let d = min(mainClips[index].transitionDuration, maxDuration)
            guard d > 0.01 else { continue }
            // 转场从渲染副本里摘掉：接缝上不再有 xfade，长度因此一点不变。
            expanded.mainClips[index].transitionAfter = .none
            // 画面：前一段灭掉后半程、后一段亮起前半程。
            expanded.mainClips[index].videoFadeOutDuration = d / 2
            expanded.mainClips[index + 1].videoFadeInDuration = d / 2
            // 声音跟着走同样的斜坡。今天一条有转场的边本来就会把用户设的音频
            // 渐变换成转场时长（AudioFade.effective），这里保持同一口径。
            expanded.mainClips[index].fadeOutDuration = d / 2
            expanded.mainClips[index + 1].fadeInDuration = d / 2
        }

        for index in mainClips.indices {
            let after = index < durations.count ? durations[index] : 0
            let before = index > 0 ? durations[index - 1] : 0
            // 缝根本不成立（有空隙 / 余料不够）的，把转场从**渲染用的副本**里
            // 摘掉，别让下游各自再判一次。已相叠的缝 after 是 0 但缝是成立的，
            // 不能连它一起摘 —— 用 capacity 判，不是用 after 判。
            // 压黑那条路上面已经把 transitionAfter 清掉了，别再按容量判一次把
            // 刚写好的渐变当成"不成立"——用 mainClips（原件）问，不是 expanded。
            if case .available = transitionCapacity(afterMainIndex: index) {} else {
                expanded.mainClips[index].transitionAfter = .none
            }
            if after > 0 {
                expanded.mainClips[index].transitionDuration = after
                // 这条缝向**我的尾巴**借多少：素材秒 = 时间线秒 × 变速。
                let tail = Self.borrowSplit(
                    outgoing: mainClips[index], incoming: mainClips[index + 1], duration: after
                ).fromTail
                expanded.mainClips[index].sourceDuration += tail * expanded.mainClips[index].speed
            }
            if before > 0 {
                // 上一条缝向**我的头**借多少。头部前移这么多，起点跟着往前挪同
                // 样多 —— 片段在时间线上的**可见**位置没变，变的是它多带了一段
                // 用来做转场的引子。借不到（头料为 0）就是 0，那条缝的窗口整个
                // 落在接缝之后，照样成立。
                let head = Self.borrowSplit(
                    outgoing: mainClips[index - 1], incoming: mainClips[index], duration: before
                ).fromHead
                expanded.mainClips[index].sourceStart -= head * expanded.mainClips[index].speed
                expanded.mainClips[index].sourceDuration += head * expanded.mainClips[index].speed
                expanded.mainClips[index].timelineStart -= head
            }
        }
        return expanded
    }
}
