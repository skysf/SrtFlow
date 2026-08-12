import CoreGraphics
import Foundation
import SrtFlowCore

/// 定格的产品常量。
enum FreezeFrame {
    /// 定格段默认插多长。插进去就是普通图片段，拖边缘随便改
    /// （上限 `StillImageClipFactory.stillDuration`）。
    static let defaultDuration = 2.0
}

extension EditClip {

    /// 由这一段在 `time` 处的样子造一个定格段。
    ///
    /// 画面必须和切口左边最后一帧**完全一致**，所以静态变换全部照抄
    /// （PNG 是未裁剪的原始帧，继承 crop 后画面对得上）。
    ///
    /// 有关键帧动画时不能直接抄 `animation`：定格段只有一帧，动画会让它在这
    /// 2 秒里继续飘，接缝处直接跳一下。取那一刻的动画值烘成静态值才对得齐。
    func makeFreezeClip(
        image: URL,
        still: URL,
        info: MediaInfo?,
        at time: Double,
        duration: Double = FreezeFrame.defaultDuration,
        canvas: CGSize,
        isOverlay: Bool
    ) -> EditClip {
        var freeze = EditClip(
            sourceURL: still,
            sourceStart: 0,
            sourceDuration: duration,
            timelineStart: time,
            // 静帧视频本来就没有音轨，静音只是把意图写明白。
            isMuted: true,
            // 切口两边都是硬切。原段自己的转场在 split 里已经跟着右半走了。
            transitionAfter: .none,
            overlayFraction: overlayFraction,
            overlayAnchor: overlayAnchor,
            flippedHorizontally: flippedHorizontally,
            flippedVertically: flippedVertically,
            crop: crop,
            info: info,
            stillImageURL: image
        )
        if isAnimated {
            freeze.placement = animatedPlacement(atTimeline: time, canvas: canvas, isOverlay: isOverlay)
            freeze.rotationDegrees = animatedRotation(atTimeline: time)
            freeze.opacity = animatedOpacity(atTimeline: time)
        } else {
            freeze.placement = placement
            freeze.rotationDegrees = rotationDegrees
            freeze.opacity = opacity
        }
        return freeze
    }
}

// MARK: - 时间线的纯值变换（分割、定格插入）
//
// 这里只动 `TimelineState`，不碰 AVFoundation / ffmpeg / 磁盘 / UI。
// 单独一个文件有两个原因：
//   1. `VideoEditProject.swift` 已经在 AGENTS.md 的超标待瘦身名单上，
//      这些块职责独立，顺手搬出来；
//   2. 自检脚本是**直接挑源文件编**的（SwiftPM 不允许两个 target 共用源文件），
//      纯值变换单独成文件才能脱离整个 App 回归 —— 见
//      `scripts/check-freeze-frame.sh`。

extension TimelineState {

    /// 把主轨数组顺序归一成时间顺序。
    ///
    /// 主轨的下游全都假设「数组顺序 = 时间顺序」：A/B 合成轨的插入游标只会前进
    /// （乱序时 `insertTimeRange` 会把已插好的段往后挤 —— 表现为黑屏/画面错时）、
    /// 转场按数组相邻配对、auto 画布取数组第一段的尺寸。磁吸开着时 `packMain()`
    /// 维持这个不变量；磁吸关掉时拖动只改 `timelineStart`、跨轨挪动直接 append，
    /// 顺序就散了 —— 改动入口和打开工程时都要调这里修正。
    /// 起点相同（理论上不该有）保持原相对顺序，排序结果可复现。
    mutating func sortMainClipsByStart() {
        let ordered = zip(mainClips, mainClips.dropFirst())
            .allSatisfy { $0.timelineStart <= $1.timelineStart }
        guard !ordered else { return }
        mainClips = mainClips.enumerated()
            .sorted { ($0.element.timelineStart, $0.offset) < ($1.element.timelineStart, $1.offset) }
            .map(\.element)
    }

    /// 在 `time` 处把一段切成两半。左半保留原来的身份（id 不变），右半是新的一段。
    mutating func split(clipID: UUID, at time: Double) {
        guard let location = location(of: clipID) else { return }
        var clips = self[track: location.track]
        var left = clips[location.clipIndex]
        guard left.contains(time: time) else { return }

        let leftSourceLength = (time - left.timelineStart) * left.speed
        var right = left
        // 右半是新的一段，得有自己的身份，链接组保持一致。
        right = EditClip(
            sourceURL: left.sourceURL,
            isAudioOnly: left.isAudioOnly,
            sourceStart: left.sourceStart + leftSourceLength,
            sourceDuration: left.sourceDuration - leftSourceLength,
            speed: left.speed,
            timelineStart: time,
            isMuted: left.isMuted,
            volume: left.volume,
            linkGroup: left.linkGroup,
            transitionAfter: left.transitionAfter,
            transitionDuration: left.transitionDuration,
            overlayFraction: left.overlayFraction,
            overlayAnchor: left.overlayAnchor,
            placement: left.placement,
            rotationDegrees: left.rotationDegrees,
            opacity: left.opacity,
            flippedHorizontally: left.flippedHorizontally,
            flippedVertically: left.flippedVertically,
            crop: left.crop,
            // 关键帧锚在源时间上：两半带同一份轨，各自只播自己窗口内的段落，
            // 接缝处数值天然连续。
            animation: left.animation,
            info: left.info,
            audioAssetDuration: left.audioAssetDuration,
            // 图片段的身份必须跟过来：`sourceURL` 只是随时会被系统清掉的静帧缓存，
            // 丢了 `stillImageURL` 的话，右半段会把缓存 mp4 当真实素材写进工程 ——
            // 缓存一清这段就再也无法从原图重建了。
            stillImageURL: left.stillImageURL
        )
        right.needsStillConversion = left.needsStillConversion
        // 标记同样锚在源时间上，所以两半各带一份**完整**的标记表，各自只画落在
        // 自己窗口里的那些 —— 切口两边谁也不会丢标记，跟关键帧一个处理法。
        right.markers = left.markers
        left.sourceDuration = leftSourceLength
        // 切口是硬切，原来的转场跟着右半走。
        left.transitionAfter = .none

        clips[location.clipIndex] = left
        clips.insert(right, at: location.clipIndex + 1)
        self[track: location.track] = clips
    }

    /// 这一段在主轨上牵扯着转场吗（自己往后叠，或者被前一段叠上来）。
    ///
    /// **牵扯转场的段不给定格**，因为转场时长有个「不超过两边任一段 45%」的上限
    /// （`transitionOverlap`）：定格把这一段切短之后，那个上限会跟着缩，于是
    /// `packMain()` 让后面的画面移动的距离**不等于**定格时长，而音频只会老老实实
    /// 顺推一个定格时长 —— 从切口往后声画就永久错开了。
    ///
    /// 实测：A 在 10s 结束、与 B 有 1s 转场，在 A 的 8.5s 定格，B 位移 2.325s
    /// 而音频位移 2.0s，错位 0.325s。
    ///
    /// 要真正支持这种情况，就得按重排后的实际时间映射去推音频（每条转场缩多少
    /// 各不相同，连定格段自己的落点都会变），复杂度远超这个功能该有的分量。
    /// 先禁掉，等有真实需求再说。
    func participatesInMainTransition(clipID: UUID) -> Bool {
        guard let index = mainClips.firstIndex(where: { $0.id == clipID }) else { return false }
        if transitionOverlap(afterMainIndex: index) > 0 { return true }
        if index > 0, transitionOverlap(afterMainIndex: index - 1) > 0 { return true }
        return false
    }

    /// 播放头是不是落在主轨某个转场的**叠化区**里。
    ///
    /// 叠化区显示的是两段合成出来的画面，从单个源素材抽帧必然和眼睛看到的对不上
    /// —— 定格按钮在这里要置灰。（`participatesInMainTransition` 已经覆盖了主轨的
    /// 这一情形，但两条的理由不同，各留各的。）
    func isInsideMainTransition(time: Double) -> Bool {
        for index in mainClips.indices {
            let overlap = transitionOverlap(afterMainIndex: index)
            guard overlap > 0 else { continue }
            let end = mainClips[index].timelineEnd
            if time > end - overlap - 0.001 && time < end + 0.001 { return true }
        }
        return false
    }

    /// 定格插入：把 `clipID` 在 `time` 处切开，同轨切口右边的一切让出
    /// `freeze` 那么长的位置，定格段落进中间。
    ///
    /// 目标在**主轨**时音频轨也跟着让位（= 一次真正的插入编辑）：跨在切口上的
    /// 音频段先切开再推右半，不切的话它的后半段会比画面早一整个定格时长。
    /// 目标在画中画轨时只动那一条轨 —— 一个小窗的定格不该把整条节目的声音推走。
    ///
    /// 字幕、形状标注一律不动（产品决定，见 docs/architecture/）。
    mutating func insertFreeze(_ freeze: EditClip, splitting clipID: UUID, at time: Double) {
        guard let location = location(of: clipID),
              clip(with: clipID)?.contains(time: time) == true else { return }
        let duration = freeze.timelineDuration
        guard duration > 0 else { return }

        split(clipID: clipID, at: time)

        // 同轨让位。切口右边的一切（含刚切出来的右半）整体后挪，定格段填进空档。
        // 磁吸开着时 `packMain()` 之后还会按数组顺序重排一遍，这里的位移是给
        // 磁吸关着的情况用的 —— 一条代码路径两种情况都对。
        var clips = self[track: location.track]
        for index in clips.indices where clips[index].timelineStart >= time - 0.0005 {
            clips[index].timelineStart += duration
        }
        var placed = freeze
        placed.timelineStart = time
        clips.insert(placed, at: location.clipIndex + 1)
        self[track: location.track] = clips

        guard location.track.isMain else { return }

        let straddling = audioTracks.flatMap(\.clips).filter { $0.contains(time: time) }.map(\.id)
        for id in straddling { split(clipID: id, at: time) }
        for lane in audioTracks.indices {
            for index in audioTracks[lane].clips.indices
            where audioTracks[lane].clips[index].timelineStart >= time - 0.0005 {
                audioTracks[lane].clips[index].timelineStart += duration
            }
        }
    }
}

// MARK: - 跨轨落地

/// 垂直拖动能落到的行。放在这里（而不是 `VideoEditProject` 里）是为了让跨轨落地
/// 保持成纯值变换、自检够得着。
enum TrackDropTarget: Equatable {
    case main
    case overlay(Int)
    case newOverlayTop
    case audio(Int)
    case newAudioBottom
}

extension TimelineState {

    /// 把剪辑搬到另一条轨。行的上下顺序就是画面的叠放顺序。
    ///
    /// 只搬**被直接拖的**那一个：跟随块（链接音频、多选的伙伴）留在各自的轨上，
    /// 由调用方在**同一次** `perform` 里按同一个 delta 平移 —— 否则视频换轨、
    /// 音频留在旧时刻，就是 A/V 错位。
    ///
    /// 到岸之后的让位仍用「挤开重叠」：目标轨上的障碍在手势开始时并不知道
    /// （那时还不知道会落到哪条轨），所以这一步没法和拖动中的预览同源。
    /// 同轨移动**不**走这里，它必须走 `ClipDragPlan.resolve`。
    mutating func relocateClip(_ id: UUID, to target: TrackDropTarget, magnet: Bool) {
        guard let clip = self.clip(with: id) else { return }
        // 手动摘下来，先别清空轨 —— target 里的轨编号是按当前排布算的，
        // 这时候清空轨会让编号移位插错行。收尾再统一清理。
        if let location = location(of: id) {
            var clips = self[track: location.track]
            clips.remove(at: location.clipIndex)
            self[track: location.track] = clips
        }
        var moved = clip
        moved.timelineStart = max(0, clip.timelineStart)
        moved.transitionAfter = .none

        switch target {
        case .main:
            if magnet {
                let rest = mainClips
                let insertion = TimelineSnap.mainInsertion(
                    among: rest,
                    moving: [moved],
                    draggedCenter: moved.timelineStart + moved.timelineDuration / 2
                )
                mainClips.insert(moved, at: min(insertion.index, mainClips.count))
            } else {
                mainClips.append(moved)
            }
        case .overlay(let index):
            if overlayTracks.indices.contains(index) {
                overlayTracks[index].clips.append(moved)
                overlayTracks[index].clips.sort { $0.timelineStart < $1.timelineStart }
            } else {
                overlayTracks.append(EditLane(clips: [moved]))
            }
        case .newOverlayTop:
            // 数组末尾 = 层级最高 = 显示在最上面一行。
            overlayTracks.append(EditLane(clips: [moved]))
        case .audio(let index):
            if audioTracks.indices.contains(index) {
                audioTracks[index].clips.append(moved)
                audioTracks[index].clips.sort { $0.timelineStart < $1.timelineStart }
            } else {
                audioTracks.append(EditLane(clips: [moved]))
            }
        case .newAudioBottom:
            audioTracks.append(EditLane(clips: [moved]))
        }

        // 挤开重叠（主轨磁吸时 packMain 会处理）。
        if !(target == .main && magnet) {
            let clamped = clampedStart(id: id, proposed: moved.timelineStart)
            update(id) { $0.timelineStart = clamped }
        }
        // 磁吸关掉落到主轨是裸 append，数组顺序要跟着时间走。
        sortMainClipsByStart()
        pruneEmptyTracks()
    }

    /// 把 `proposed` 让开同轨上别的块（重叠时往更近的那一侧躲）。
    /// **只给跨轨落地用** —— 同轨移动的可行区间由 `ClipDragPlan` 冻结时算好。
    func clampedStart(id: UUID, proposed: Double) -> Double {
        guard let location = location(of: id), let clip = self.clip(with: id) else { return max(0, proposed) }
        var start = max(0, proposed)
        let neighbours = self[track: location.track].filter { $0.id != id }
        let duration = clip.timelineDuration
        for other in neighbours.sorted(by: { $0.timelineStart < $1.timelineStart }) {
            let overlaps = start < other.timelineEnd && other.timelineStart < start + duration
            guard overlaps else { continue }
            // 往右让还是往左让，取决于想去的位置更靠哪边。
            if proposed + duration / 2 < other.timelineStart + other.timelineDuration / 2 {
                start = max(0, other.timelineStart - duration)
            } else {
                start = other.timelineEnd
            }
        }
        return start
    }
}

// MARK: - 拖动落地（纯值变换）

extension TimelineState {

    /// 这一轮拖动里跟着一起动的**剪辑**名单。
    ///
    /// 吸附候选、拖动中的渲染位移、落地三处必须用同一份名单，所以它是纯值的：
    /// `VideoEditProject` 只负责把开关和当前选择喂进来，自检直接调这里。
    ///
    /// 两条容易写错的地方：
    ///
    /// 1. **链接组要为每一个成员各展开一次**，不能只展开被拖的那个。框选 A、B
    ///    两段、各自都有分离出来的音频时，只展开 A 的话 B 会动、B 的音频不动 ——
    ///    直接 A/V 错位（复审报的第 2 条）。所以先并多选、再整批展开链接。
    /// 2. **磁吸开着、而这一轮拖的不是主轨块时，主轨成员整批剔除**。磁吸下主轨
    ///    块的位置只由 `packMain` 决定：跟着平移在拖动中画出来了，松手 `perform`
    ///    重排又把它排回去，等于骗了用户一路。剔除之后「拖动中看到的 = 松手落到
    ///    的」重新成立。想让主轨块跟着走，关掉磁吸即可。
    ///    - 代价写在明处：主轨块和它分离出来的音频被这条规则拆开时，磁吸下本来
    ///      也没法同步移动（长期约束见 docs/architecture/timeline-drag-gestures.md）。
    func draggingClipIDs(
        seed: Set<UUID>,
        linkage: Bool,
        magnetPinsMainTrack: Bool
    ) -> Set<UUID> {
        var ids = seed
        if linkage {
            for id in seed { ids.formUnion(linkedClipIDs(of: id)) }
        }
        guard magnetPinsMainTrack else { return ids }
        return ids.filter { location(of: $0)?.track.isMain != true }
    }

    /// 一轮拖动落地的全部状态变换。
    ///
    /// `VideoEditProject.commitDrag` 只负责把它包进**一次** `perform`
    /// （一步撤销 + 一次预览重建）——变换本身留在这里，自检才够得着。
    ///
    /// 位置**只来自** `resolution`：拖动中渲染的就是这一份，落地不再算第二遍。
    ///
    /// `magnet` 传的是**全局磁吸开关**（不是「拖的是不是主轨块」）。它开着时
    /// 这里就把 `packMain()` 做完，产物即最终状态 —— `perform` 之后那次重排
    /// 因此是幂等的，自检在纯值层看到的也就是 App 里真正落下的位置。以前这里
    /// 不排、只靠 `perform` 排，自检便测不到那一步（复审指出的假绿）。
    mutating func applyDrag(
        _ plan: ClipDragPlan,
        resolution: DragResolution,
        crossTrack target: TrackDropTarget?,
        magnet: Bool
    ) {
        // 1) 整组平移同一个 delta。逐块独立夹取会把相对错位夹坏 ——
        //    「拖 A、B 跟着」会变成「A 被旧位置的 B 顶回原地，整组没动」。
        move(plan.members, by: resolution.delta)

        if let target {
            // 2) 跨轨：只搬被直接拖的那个，跟随块留在各自轨上（时刻第 1 步已定好）。
            relocateClip(plan.draggedID, to: target, magnet: magnet)
        } else if let insertion = resolution.mainInsertion {
            // 3) 主轨磁吸：整组按相对顺序插进**同一条缝**，落点与拖动中那条指示线
            //    同源（都来自 TimelineSnap.mainInsertion）。
            let movingIDs = Set(plan.members.map(\.id))
            let movingMain = mainClips.filter { movingIDs.contains($0.id) }
            var clips = mainClips.filter { !movingIDs.contains($0.id) }
            clips.insert(contentsOf: movingMain, at: min(insertion.index, clips.count))
            mainClips = clips
        }
        // 4) 磁吸：主轨在这里就排好。下面算「实际位移」必须在排完之后 ——
        //    排之前的位置是中间态，拿它去平伙伴就会差一个身位。
        if magnet { packMain() }
        realignCompanions(plan, magnet: magnet)
        // 磁吸关掉的拖动只改了 timelineStart，数组顺序要跟着时间走
        //（磁吸开的分支 packMain 之后本来就有序，这里是幂等的）。
        sortMainClipsByStart()
    }

    /// 被拖的那个最终落在哪儿，其余成员就跟着挪同样多。
    ///
    /// 两条分支都要它，理由是同一个：**落点可能不等于 `resolution.delta`**。
    /// 磁吸插空会把被拖块挤到缝的位置；跨轨到岸会被 `clampedStart` 让开目标轨上
    /// 的占位。只搬被拖的那个、伙伴留在第 1 步的位置上，整组的相对错位就被拆散了
    /// （链接音频当场 A/V 错位 —— 复审报的就是跨轨这一条）。
    ///
    /// 位移按**冻结 span + 实际 delta** 算绝对值，所以在第 1 步之上写第二次是
    /// 幂等的，不会叠成双倍。
    ///
    /// 主轨成员在磁吸下由 `packMain` 定位，不参与 —— 平了也会被排回去。
    private mutating func realignCompanions(_ plan: ClipDragPlan, magnet: Bool) {
        guard let moved = clip(with: plan.draggedID) else { return }
        let actual = moved.timelineStart - plan.draggedSpan.start
        let pinned = magnet ? Set(mainClips.map(\.id)) : []
        move(plan.members.filter { !pinned.contains($0.id) }, by: actual)
    }

    /// 把一组成员整体平移 `delta` 秒。三类成员改的字段不同，位移只有一个。
    ///
    /// 落点一律按**冻结的 span + delta** 算绝对值，不是在当前值上叠加 ——
    /// 磁吸主轨那条分支会拿实际落点把非主轨成员再平一次，叠加式的写法在那里
    /// 会变成双倍位移。字幕 cue 走 `LinkedSubtitleEditing.setStarts`（两轨同步 +
    /// 重排 + reindex），整批一次交给它，别在循环里一条条调：那样每条都要重排
    /// 一次整轨。
    private mutating func move(_ members: [ClipDragPlan.Member], by delta: Double) {
        var cueStarts: [UUID: Double] = [:]
        for member in members {
            let start = max(0, member.span.start + delta)
            switch member.kind {
            case .clip:
                update(member.id) { $0.timelineStart = start }
            case .shape:
                updateShape(member.id) { $0.timelineStart = start }
            case .subtitleCue:
                cueStarts[member.id] = start
            }
        }
        guard !cueStarts.isEmpty, var original = subtitle else { return }
        var companion = subtitleCompanion ?? SubtitleCompanion()
        LinkedSubtitleEditing.setStarts(cueStarts, original: &original, companion: &companion)
        subtitle = original
        subtitleCompanion = companion.hasPersistentData ? companion : nil
    }
}
