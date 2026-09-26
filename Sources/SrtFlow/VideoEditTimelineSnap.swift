import Foundation
import SrtFlowCore

// MARK: - 时间线拖动的吸附与对齐线
//
// 全是纯值函数，不碰 AppKit / SwiftUI / AVFoundation —— 自检
// （scripts/check-timeline-snap.sh）把这个文件直接编进二进制跑。
// 别把它们挪回 `VideoEditProject.swift`：那个文件拖着整个 App，
// 一挪自检就编不动了（和 `VideoEditTimelineEdits.swift` 同一条约束）。

enum TimelineSnap {

    /// 吸附阈值（视图点）。与预览画布的中心吸附（`CenterSnap.tolerance`）同量级。
    static let thresholdPixels: Double = 7

    /// 判「这条候选被块的某条边压住了」的容差（视图点）。落点是精确算出来的，
    /// 这里只用来吃掉浮点尾巴，别当成第二个吸附半径。
    static let guideEpsilonPixels: Double = 0.5

    struct Result: Equatable {
        /// 吸附后的起点。
        var start: Double
        /// 要亮的对齐线时刻（升序、去重）。空 = 这一拍没吸上任何东西。
        var guides: [Double]

        var isSnapped: Bool { !guides.isEmpty }
    }

    /// 把 `proposedStart` 吸到最近的参考点上。
    ///
    /// **块的两条边都参与**：起点和终点各自去够每个候选，所有配对里取位移最小的
    /// 那一种。只比起点的话，「我的右边缘贴上你的左边缘」永远吸不上也不亮线 ——
    /// 用户看到的就是"边缘明明碰上了却没有反应"。
    ///
    /// `minimumStart` / `maximumStart` 是这一组块整体能落的区间（不能退到负时间、
    /// 也不能穿过不动的块）。落点先被它夹一次，参考线再按夹完的位置算 ——
    /// 夹完才亮线，线和块才对得上。
    static func resolve(
        proposedStart: Double,
        duration: Double,
        candidates: [Double],
        pixelsPerSecond: Double,
        minimumStart: Double = 0,
        maximumStart: Double = .infinity
    ) -> Result {
        let clamp = { (value: Double) in min(max(minimumStart, value), max(minimumStart, maximumStart)) }
        let start = clamp(proposedStart)
        let threshold = thresholdPixels / max(pixelsPerSecond, 1)
        var bestDelta = 0.0
        var bestDistance = threshold
        for candidate in candidates {
            for delta in [candidate - start, candidate - (start + duration)] {
                let distance = abs(delta)
                // 严格小于：平手时留住先出现的候选，结果只由候选顺序决定，可预期。
                if distance < bestDistance {
                    bestDistance = distance
                    bestDelta = delta
                }
            }
        }
        let snapped = clamp(start + bestDelta)
        return Result(
            start: snapped,
            guides: alignedCandidates(
                start: snapped,
                duration: duration,
                candidates: candidates,
                pixelsPerSecond: pixelsPerSecond
            )
        )
    }

    /// 块落在 `start` 时，哪些候选正好被它的某条边压住 —— 要亮的线就是这些。
    /// 一次可能亮不止一条（右边缘贴着 A 的结尾、左边缘同时贴着 B 的开头）。
    static func alignedCandidates(
        start: Double,
        duration: Double,
        candidates: [Double],
        pixelsPerSecond: Double
    ) -> [Double] {
        let epsilon = guideEpsilonPixels / max(pixelsPerSecond, 1)
        let edges = [start, start + duration]
        var hits: [Double] = []
        for candidate in candidates
        where edges.contains(where: { abs($0 - candidate) <= epsilon }) {
            guard !hits.contains(where: { abs($0 - candidate) <= epsilon }) else { continue }
            hits.append(candidate)
        }
        return hits.sorted()
    }

    /// 拖 `movingIDs` 这组块时的参考点：0、播放头、整条时间线的末尾，
    /// 以及所有**不跟着一起动**的东西：剪辑（主轨 / 上层 / 音频）、形状、文字、滤镜段、字幕 cue 的两端，
    /// 标记（一个点）。藏起来的也算 —— 它们还占着时间线、看得见（2026-09-25 规格、2026-09-26 拍板）。
    ///
    /// 必须在手势**开始**时算一次并冻住。跟着动的伙伴（链接的音频、多选的其他块）
    /// 留在候选里的话，它们上一拍刚被挪到手指底下，这一拍就成了「离落点只差几像素」
    /// 的候选，把块吸回上一帧的位置 —— 手感就是拖不动、粘手，而且鼠标走得越慢
    /// 越粘（一拍的位移小于阈值就永远挣不脱）。
    static func candidates(
        in state: TimelineState,
        moving movingIDs: Set<UUID>,
        playhead: Double
    ) -> [Double] {
        var result: [Double] = [0, playhead]
        // 「轨道末尾」也得按**留下来的**内容算：拖的正好是最后一段时，
        // `state.duration` 就是它自己的终点，那条候选等于让块吸回原地。
        var end = 0.0
        for clip in state.allClips where !movingIDs.contains(clip.id) {
            result.append(clip.timelineStart)
            result.append(clip.timelineEnd)
            end = max(end, clip.timelineEnd)
        }
        for shape in state.shapes where !movingIDs.contains(shape.id) {
            result.append(shape.timelineStart)
            result.append(shape.timelineEnd)
            end = max(end, shape.timelineEnd)
        }
        for text in state.textOverlays where !movingIDs.contains(text.id) {
            result.append(text.timelineStart)
            result.append(text.timelineEnd)
            end = max(end, text.timelineEnd)
        }
        // 滤镜段的两端也是候选（拖它吸别人、拖别人也吸它）。但**不进 `end`**：
        // 滤镜不算时间线总长（TimelineState.duration 不看它），那条「轨道末尾」
        // 的候选不该被一段拖到片尾之外的滤镜拽长。
        for filter in state.filters where !movingIDs.contains(filter.id) {
            result.append(filter.timelineStart)
            result.append(filter.timelineEnd)
        }
        // 字幕 cue（原文、译文两条轨）和标记也是对齐点，同样不进 `end`（它们不算时间线总长）。
        // 字幕全算：几百条可能让拖动变粘，用户知道，先做再看手感（2026-09-25）。
        for cue in (state.subtitle?.cues ?? []) + (state.subtitleCompanion?.translation?.cues ?? [])
        where !movingIDs.contains(cue.id) {
            result.append(cue.start)
            result.append(cue.end)
        }
        // 标记跟着自己那段走：那段在动，它的标记也在动，不当参考点。
        for clip in state.allClips where !movingIDs.contains(clip.id) {
            result.append(contentsOf: clip.visibleMarkers.map { clip.timelineTime(of: $0) })
        }
        result.append(end)
        return result
    }

    // MARK: - 主轨磁吸的插入位置

    struct MainInsertion: Equatable {
        /// 插进 `rest` 的哪个下标。
        var index: Int
        /// 插完打包后，被拖的那一组落在哪一刻（占位框从这里画起）。
        var time: Double
        /// 那一组落地后占多长（占位框的宽度）。组内转场会叠掉一部分，所以
        /// 不一定等于成员时长之和 —— 同样在最终数组上算，框才不说谎。
        var duration: Double
    }

    /// 主轨磁吸开着时，松手会插进哪条缝、那一组会落在哪。
    ///
    /// 拖动中主轨**不再**当场重排（每一拍重排整条轨，画面一直在抖、代价还都花在
    /// 手势路径上），只画这条指示线；真正的 `packMain()` 留到松手那一下。
    /// 预览用它、落地也用它 —— 同一个函数，指示线指哪儿就落哪儿。
    ///
    /// 时刻**必须在插入之后的最终数组上算**：插进来的块会改变相邻关系，
    /// 转场能叠掉的量按两边任一段的 45% 收紧，跟着就变。拿 `rest` 的原相邻关系
    /// 算缝会说谎 —— A(10s，其后 2s 转场) + B(10s) 之间插一段 1s 的 M：
    /// 按 rest 算是 8s，实际 A→M 只能叠 0.45s，M 落在 9.55s。
    ///
    /// - Parameters:
    ///   - rest: 主轨上**不跟着动**的块，按数组顺序（= 时间顺序）。
    ///   - moving: 跟着一起动、且落在主轨上的块，保持相对顺序整组插进同一条缝。
    ///   - center: 被拖块此刻的中心时刻。
    static func mainInsertion(
        among rest: [EditClip],
        moving: [EditClip],
        draggedCenter center: Double
    ) -> MainInsertion {
        // 1) 插哪条缝：拿 rest 自己的打包布局比中心。
        let restStarts = TimelineState.packedStarts(rest)
        var index = rest.count
        for (i, clip) in rest.enumerated() where center < restStarts[i] + clip.timelineDuration / 2 {
            index = i
            break
        }
        // 2) 落在哪一刻、占多长：都在最终数组上算。
        var final = rest
        final.insert(contentsOf: moving, at: index)
        let finalStarts = TimelineState.packedStarts(final)
        let time = index < finalStarts.count ? finalStarts[index] : 0
        let lastIndex = index + moving.count - 1
        let end = lastIndex >= index && lastIndex < finalStarts.count
            ? finalStarts[lastIndex] + final[lastIndex].timelineDuration
            : time
        return MainInsertion(index: index, time: time, duration: max(0, end - time))
    }
}

// MARK: - 一轮拖动的冻结输入与落点解析

/// 时间线上一段被拖的东西（剪辑或形状）在它自己那条轨上的占位。
struct TimelineSpan: Equatable, Sendable {
    var start: Double
    var end: Double

    var duration: Double { end - start }
}

/// 一轮拖动的**冻结输入**：手势开始时算一次，之后每一拍只喂一个 `desiredDelta`。
///
/// 拖动中渲染和松手落地调的是**同一个** `resolve` —— 用户看到的位置就是最终落点。
/// 以前落地那一步偷偷多跑一遍 `clampedStart`，于是拖动中显示 9s、松手弹到 5s；
/// 凡是「只在 commit 里跑」的落点算法都是这类分叉的温床，不许再出现第二份。
struct ClipDragPlan: Equatable {

    /// 跟着一起动的一个块。
    struct Member: Equatable {
        /// 成员是哪一类。落地时改的字段不同（剪辑/形状改 `timelineStart`、
        /// 字幕 cue 要两轨同步），但**位移只有一个** —— 谁都不许自己算一份。
        enum Kind: Equatable {
            case clip
            case shape
            case text
            case subtitleCue
            case filter
        }

        var id: UUID
        var span: TimelineSpan
        /// 它**自己那条轨**上不跟着动的块的占位（升序）。整组的可行位移由所有
        /// 成员的障碍一起决定，绝不逐块独立夹取 —— 那样会把相对错位夹坏。
        var obstacles: [TimelineSpan]
        var kind: Kind = .clip
    }

    /// 被直接拖的那个（跨轨落地搬的是它，跟随块只做水平平移）。
    var draggedID: UUID
    var draggedSpan: TimelineSpan
    /// 含被拖的那个在内的全部成员。
    var members: [Member]
    /// 吸附候选（冻结，理由见 `TimelineSnap.candidates`）。
    var candidates: [Double]
    /// 主轨磁吸插空模式：主轨上不动的块 + 跟着动且在主轨上的块。
    /// nil = 自由落点模式（上层轨/音频/磁吸关掉的主轨/形状）。
    var magnet: Magnet?

    struct Magnet: Equatable {
        var rest: [EditClip]
        var moving: [EditClip]
    }

    /// 从时间线状态造这一轮的冻结输入。
    ///
    /// **障碍只收不跟着动的块**：跟着动的伙伴（链接音频、多选的其他块）算进障碍
    /// 的话，整组会被自己人挡住 —— 同轨 A=[0,5]、B=[5,10] 一起拖，A 会被 B 顶回
    /// 原地，表现是「整组一动不动」。纯值函数，自检直接调。
    static func make(
        in state: TimelineState,
        draggedID: UUID,
        movingIDs: Set<UUID>,
        candidates: [Double],
        magnetMain: Bool
    ) -> ClipDragPlan? {
        guard let dragged = state.clip(with: draggedID) else { return nil }
        return ClipDragPlan(
            draggedID: draggedID,
            draggedSpan: TimelineSpan(start: dragged.timelineStart, end: dragged.timelineEnd),
            members: clipMembers(in: state, movingIDs: movingIDs),
            // 磁吸主轨也吸、也亮线（2026-09-25 用户拍板）：块在手底下浮着，线只表示「此刻碰上」，
            // 落点照旧由插空决定（松手跳进青框）。以前这里给空候选，理由是「亮线是骗人的」。
            candidates: candidates,
            magnet: magnetMain
                ? Magnet(
                    rest: state.mainClips.filter { !movingIDs.contains($0.id) },
                    moving: state.mainClips.filter { movingIDs.contains($0.id) }
                )
                : nil
        )
    }

    /// 跟着一起动的剪辑成员（含各自轨上的障碍）。
    ///
    /// 单独抽出来是因为被直接拖的**不一定是剪辑**：拖一个选中的形状时，同一片
    /// 选择里的剪辑也要跟着走，那条路径进不了 `make`（它要求 `draggedID` 是剪辑）。
    static func clipMembers(in state: TimelineState, movingIDs: Set<UUID>) -> [Member] {
        movingIDs.compactMap { memberID in
            guard let clip = state.clip(with: memberID),
                  let location = state.location(of: memberID) else { return nil }
            return Member(
                id: memberID,
                span: TimelineSpan(start: clip.timelineStart, end: clip.timelineEnd),
                obstacles: state[track: location.track]
                    .filter { !movingIDs.contains($0.id) }
                    .map { TimelineSpan(start: $0.timelineStart, end: $0.timelineEnd) }
                    .sorted { $0.start < $1.start },
                kind: .clip
            )
        }
    }

    /// 把跟着一起动的**形状**和**字幕 cue** 挂进同一份计划（鼠标框选可以一次
    /// 选中三类，之后拖任意一个，整片都得跟着走）。
    ///
    /// 它们都没有障碍：形状行本来就允许重叠，字幕轨也不参与碰撞。挂进 `members`
    /// 的意义有两条 —— 一是落地时能拿到同一个 delta（别处再算一份必然分叉），
    /// 二是 `groupLowerDelta`（`fittedDelta` 的下界）会自动把它们算进去，整组
    /// 一起停在 0 秒，而不是剪辑还能往左、字幕已经被各自夹在 0 上，相对错位
    /// 当场压扁。
    ///
    /// 纯值函数，自检直接调。
    func adding(
        shapes: [(id: UUID, span: TimelineSpan)],
        texts: [(id: UUID, span: TimelineSpan)],
        cues: [(id: UUID, span: TimelineSpan)],
        filters: [(id: UUID, span: TimelineSpan)] = []
    ) -> ClipDragPlan {
        var plan = self
        let existing = Set(plan.members.map(\.id))
        // 跟着走的滤镜段不带障碍（同形状 / 文字）：整片一起平移，同层撞上就叠着，不挡。
        for filter in filters where !existing.contains(filter.id) {
            plan.members.append(Member(id: filter.id, span: filter.span, obstacles: [], kind: .filter))
        }
        for shape in shapes where !existing.contains(shape.id) {
            plan.members.append(Member(id: shape.id, span: shape.span, obstacles: [], kind: .shape))
        }
        for text in texts where !existing.contains(text.id) {
            plan.members.append(Member(id: text.id, span: text.span, obstacles: [], kind: .text))
        }
        for cue in cues where !existing.contains(cue.id) {
            plan.members.append(Member(id: cue.id, span: cue.span, obstacles: [], kind: .subtitleCue))
        }
        return plan
    }

    /// 自由落点的轨道才给「弹性尾部」：能把块拖到现有内容之外。
    /// 磁吸主轨最终只能插进现有故事线的某条缝，扩太远只会把插入指示线滚出视野。
    var allowsFreeLanding: Bool { magnet == nil }

    /// 整组最靠外的两条边：最早的开头、最晚的结尾。**多选时只拿这两条去吸、去亮线**，中间的块不管
    /// （2026-09-25 规格）。只有一个成员时就是被拖的那一块。
    var groupSpan: TimelineSpan {
        TimelineSpan(
            start: members.map(\.span.start).min() ?? draggedSpan.start,
            end: members.map(\.span.end).max() ?? draggedSpan.end
        )
    }

    /// 整组「谁都不许被推到负时间」的下界，**只有这一条**，不含同轨障碍。
    ///
    /// 跨轨到岸让位（`clampedStart`）要用它：往左躲一旦越过这条线，伙伴就会各自
    /// 被 `max(0, …)` 单独夹住，整组的相对错位当场压扁 —— 那正是这套计划要防的
    /// 东西。不能改拿 `fittedDelta` 的下界：那里面还叠着**源轨**上的障碍，
    /// 而块都换轨了，那些障碍已经与它无关。
    var groupLowerDelta: Double { -(members.map(\.span.start).min() ?? 0) }

    /// 把 `desired` 落到最近的**合法**位移上（自由落点模式的落点核心）。
    ///
    /// 「合法」= 没有任何成员压到自己轨上不动的块，且整组不进负时间。障碍
    /// **不再是墙**：指针把块拖过障碍另一侧时，位移直接落到那一侧的接触面 ——
    /// 这就是「同轨越过邻居、直接落进间隙」（2026-08-23 起；以前只能先挪去
    /// 别的轨再挪回来）。就近原则保住了老手感：指针没过去时，落点仍是这一侧
    /// 的接触面；装不下被拖块的间隙永远不会成为落点。
    ///
    /// 返回的 `lower`/`upper` 是落点所在**空档**的位移边界：吸附只许在空档内
    /// 挪（吸出去就又压上别人了），正好嵌满的间隙两端相等。
    func fittedDelta(desired: Double) -> (delta: Double, lower: Double, upper: Double) {
        let floor = groupLowerDelta
        let epsilon = 0.0001
        var d = max(desired, floor)

        // 每个成员的每个障碍都排除掉一段位移开区间（落进去就会重叠）。
        // 一开始就重叠的障碍（老工程/异常态）不设限，否则整组会被一个本来就
        // 压着的块锁死在原地 —— 与老 allowedDeltaRange 同一条豁免。
        var forbidden: [(lo: Double, hi: Double)] = []
        for member in members {
            for obstacle in member.obstacles {
                let lo = obstacle.start - member.span.end
                let hi = obstacle.end - member.span.start
                guard !(lo < -epsilon && hi > epsilon) else { continue }
                forbidden.append((lo, hi))
            }
        }
        // 合并重叠的区间。**严格重叠才并**：两段只是端点相接时，接点是一个
        // 「正好嵌满」的合法落点（比如 5 秒的块嵌进两块之间正好 5 秒的缝）。
        forbidden.sort { $0.lo < $1.lo }
        var merged: [(lo: Double, hi: Double)] = []
        for interval in forbidden {
            if var last = merged.last, interval.lo < last.hi - epsilon {
                last.hi = max(last.hi, interval.hi)
                merged[merged.count - 1] = last
            } else {
                merged.append(interval)
            }
        }

        // 落在某段禁区里：往更近的那一侧接触面躲；往左不许越过整组下界。
        if let hit = merged.first(where: { d > $0.lo + epsilon && d < $0.hi - epsilon }) {
            let leftAllowed = hit.lo >= floor - epsilon
            d = leftAllowed && d - hit.lo <= hit.hi - d ? hit.lo : hit.hi
        }

        // 落点所在空档的边界（给吸附当夹取范围）。
        var lower = floor
        var upper = Double.infinity
        for interval in merged {
            if interval.hi <= d + epsilon { lower = max(lower, interval.hi) }
            if interval.lo >= d - epsilon { upper = min(upper, interval.lo) }
        }
        return (d, lower, max(lower, upper))
    }

    /// 被拖块自己轨上的「装不下的真间隙」：两段障碍之间（或 0 点与第一段之间）
    /// 有空档、但宽度不够放下被拖块，且 `center` 正悬在里面。
    ///
    /// 只在「组里除了被拖块，其余成员都没有障碍」时提供：让位只推被拖块自己
    /// 的轨，别的成员要是也会撞上各自轨上的块，塞进来就是顾此失彼。
    private func undersizedHole(centeredAt center: Double) -> (start: Double, width: Double)? {
        guard let dragged = members.first(where: { $0.id == draggedID }),
              members.allSatisfy({ $0.id == draggedID || $0.obstacles.isEmpty })
        else { return nil }
        let duration = draggedSpan.duration
        var previousEnd = 0.0
        for obstacle in dragged.obstacles {
            let width = obstacle.start - previousEnd
            if width > 0.0005, width < duration - 0.0005,
               center >= previousEnd, center < obstacle.start {
                return (previousEnd, width)
            }
            previousEnd = max(previousEnd, obstacle.end)
        }
        return nil
    }

    /// 解析这一拍的落点。`desiredDelta` 是手势位移换算出来的原始位移。
    func resolve(desiredDelta: Double, pixelsPerSecond: Double) -> DragResolution {
        if let magnet {
            // 磁吸模式只有「不进负时间」这一条界（插空不看同轨障碍）。
            let clamped = max(desiredDelta, groupLowerDelta)
            // 磁吸主轨：块自由浮动跟手，落点由插空决定，不吸别人的边缘
            //（吸了也会被 packMain 覆盖，亮线是骗人的）。
            //
            // 画的位置夹在 0 以上，但插空判定用**未夹**的中心：块顶到时间线左端
            // 之后中心就不动了，恰好压在第一段的中点上，`center < mid` 永远为假
            // —— 用户往左拖到底也插不到第一段前面去。
            let center = draggedSpan.start + desiredDelta + draggedSpan.duration / 2
            let insertion = TimelineSnap.mainInsertion(
                among: magnet.rest, moving: magnet.moving, draggedCenter: center
            )
            // 浮着的那一块照样吸、照样亮线，只改画出来的位置：插空判定用的是上面的原始中心，
            // 吸附挪的那几个点不许改变插进哪条缝（落地的位置由 packMain 定，和这里的位移无关）。
            let group = groupSpan
            let snapped = TimelineSnap.resolve(
                proposedStart: group.start + clamped, duration: group.duration, candidates: candidates,
                pixelsPerSecond: pixelsPerSecond, minimumStart: group.start + groupLowerDelta
            )
            return DragResolution(delta: snapped.start - group.start, guides: snapped.guides, mainInsertion: insertion)
        }

        // 指针中心悬在一个**装不下**的真间隙上：落点 = 间隙起点，右侧让位
        // 腾出（素材时长 − 间隙宽度）。这就是「把 6 秒的素材塞进 5 秒的缝」——
        // 以前只能借道上层轨、还会落成重叠，现在同轨一步到位（2026-08-23）。
        let center = draggedSpan.start + desiredDelta + draggedSpan.duration / 2
        if let hole = undersizedHole(centeredAt: center) {
            let delta = hole.start - draggedSpan.start
            // 让位只推被拖块的轨；整组仍不许被这一步带进负时间。
            if delta >= groupLowerDelta - 0.0005 {
                return DragResolution(
                    delta: delta,
                    guides: TimelineSnap.alignedCandidates(
                        start: hole.start,
                        duration: draggedSpan.duration,
                        candidates: candidates,
                        pixelsPerSecond: pixelsPerSecond
                    ),
                    mainInsertion: nil,
                    sameTrackPush: SameTrackPush(
                        at: hole.start,
                        amount: draggedSpan.duration - hole.width
                    )
                )
            }
        }

        // 自由落点：先落进最近的合法间隙（可越过障碍），再在那个空档内吸附。
        // 吸的是整组最靠外的两条边（`groupSpan`）：单选时就是被拖的那一块。
        let fit = fittedDelta(desired: desiredDelta)
        let group = groupSpan
        let snapped = TimelineSnap.resolve(
            proposedStart: group.start + fit.delta,
            duration: group.duration,
            candidates: candidates,
            pixelsPerSecond: pixelsPerSecond,
            minimumStart: group.start + fit.lower,
            maximumStart: group.start + fit.upper
        )
        return DragResolution(
            delta: snapped.start - group.start,
            guides: snapped.guides,
            mainInsertion: nil
        )
    }
}

/// `ClipDragPlan.resolve` 的结果：渲染和落地共用。
struct DragResolution: Equatable {
    /// 整组的最终位移（秒）。**所有**成员都平移这一个值。
    var delta: Double
    /// 要亮的对齐线。
    var guides: [Double]
    /// 磁吸主轨的插入位置（自由落点模式为 nil）。
    var mainInsertion: TimelineSnap.MainInsertion?
    /// 同轨「塞进装不下的间隙」：落地时把被拖块自己轨上、`at` 右边的不动内容
    /// 整体右移 `amount` 腾出位置（nil = 不用腾）。跨轨落地时忽略 —— 块都去了
    /// 别的轨，这里腾出来的就是个没人用的空洞。
    var sameTrackPush: SameTrackPush? = nil
}

/// 「塞进装不下的间隙」要腾的位置。
struct SameTrackPush: Equatable {
    /// 间隙起点（= 被拖块的落点）。
    var at: Double
    /// 要腾出的长度（= 素材时长 − 间隙宽度）。
    var amount: Double
}
