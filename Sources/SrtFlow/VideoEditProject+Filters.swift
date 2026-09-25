import Foundation

// 滤镜段的增删改查。产品口径见 docs/architecture/filters.md。
//
// 全部走 `rebuildsPreview: false`：滤镜**不参与 AV 合成** —— 预览是把 LUT 挂在
// 播放器视图上（`VideoEditFilterPreview.swift`），合成条目一个字节都没变。
// 白重建一次要 `replaceCurrentItem`，画面会黑一下（同形状/文字那条口径）。

@MainActor
extension VideoEditProject {

    // MARK: - 选中

    /// 只选中了一段滤镜时的那一段（检查器的滤镜区、库面板「点卡片 = 换种类」认它）。
    /// 多段一起选中（框选 / ⌘A）时是 nil；全部选中的段见 `selectedFilterIDs`。
    var selectedFilterID: UUID? { selection.soleFilterID }

    var selectedFilter: FilterClip? {
        guard let id = selection.soleFilterID else { return nil }
        return state.filters.first { $0.id == id }
    }

    // MARK: - 加

    /// 在播放头处加一段滤镜。
    ///
    /// 落点口径（2026-09-21 拍板）：**从播放头开始**、默认 3s、落在这段时间内
    /// **空着的最低层**，没有空层就往上开一层。叠加是合法的，所以这里没有
    /// 「撞车」那套让位/截短规则 —— 撞上了就摞上去。
    @discardableResult
    func addFilter(_ preset: FilterPreset) -> UUID {
        let start = max(0, clock.displayTime)
        let duration = FilterClip.defaultDuration
        let layer = state.lowestFreeFilterLayer(start: start, end: start + duration)
        let filter = FilterClip(
            preset: preset, timelineStart: start, duration: duration, layer: layer
        )
        perform(rebuildsPreview: false) { $0.filters.append(filter) }
        selectFilter(filter.id)
        return filter.id
    }

    /// 落一段滤镜到指定的位置和层（拖卡片落地走这条）。
    ///
    /// 和 `addFilter(_:)` 的分工：那个是「在播放头加一段」，落点规则自己算；
    /// 这个是「就落在这儿」，落点已经由拖动中的落点框定好了 —— 两者必须是
    /// 同一次 `perform`、同一种选中行为，不然撤销栈和选中态会各说各的。
    @discardableResult
    func addFilter(
        _ preset: FilterPreset, at start: Double, duration: Double, layer: Int
    ) -> UUID {
        let filter = FilterClip(
            preset: preset,
            timelineStart: max(0, start),
            duration: max(FilterClip.minimumDuration, duration),
            layer: max(0, layer)
        )
        perform(rebuildsPreview: false) { $0.filters.append(filter) }
        selectFilter(filter.id)
        return filter.id
    }

    /// 滤镜库里点一张卡片。
    ///
    /// **选中了某一段就替换它的种类**（时长、强度、层号都不动 —— 「换个滤镜
    /// 试试」是最常见的意图，和转场库「点卡片只换种类不改时长」同一口径）；
    /// 没选中就在播放头加一段新的。
    func applyFilterFromLibrary(_ preset: FilterPreset) {
        if let id = selection.soleFilterID, state.filters.contains(where: { $0.id == id }) {
            setFilterPreset(id, preset)
        } else {
            addFilter(preset)
        }
    }

    // MARK: - 改

    func setFilterPreset(_ id: UUID, _ preset: FilterPreset) {
        perform(rebuildsPreview: false) { $0.updateFilter(id) { $0.preset = preset } }
    }

    /// 拖强度滑块（连续版本）。松手由调用方 `endLiveEdit(rebuildsPreview: false)`
    /// 结成一步撤销。
    func liveSetFilterStrength(_ id: UUID, _ strength: Double) {
        beginLiveEdit()
        liveApply { $0.updateFilter(id) { $0.strength = strength } }
    }

    func setFilterStrength(_ id: UUID, _ strength: Double) {
        perform(rebuildsPreview: false) { $0.updateFilter(id) { $0.strength = strength } }
    }

    /// 拖滤镜块两端裁切（实时版本）。`deltaSeconds` 是手势开始以来的总位移。
    ///
    /// 与形状/文字同一套口径：没有素材边界，起点端最多回拉到 0，两端收缩的
    /// 下限是 `FilterClip.minimumDuration`。
    /// 拖滤镜块两端裁切。滤镜单选、和别的选择互斥，所以只裁它自己（范围规矩在 `TimelineTrim`）。
    func liveTrimFilter(_ id: UUID, leading: Bool, deltaSeconds: Double) {
        liveTrim(anchor: TimelineTrim.Member(id: id, kind: .filter), leading: leading, deltaSeconds: deltaSeconds)
    }

    // MARK: - 复制 / 剪切 / 粘贴
    //
    // 只认滤镜段。编辑器里别的东西（剪辑、形状、文字、字幕）**本来就没有**
    // 复制粘贴 —— `handleEvent` 凡带 ⌘/⌥/⌃ 一律放行给系统，从来没人接过。
    // 这一刀只按用户点的范围补滤镜；接别的类型是另一件事（剪辑还牵着素材引用、
    // 链接音频和转场），不顺手做。

    /// ⌘C。没选中滤镜段就返回 nil —— 调用方据此让菜单项变灰。
    func copySelectedFilter() -> FilterClip? {
        guard let filter = selectedFilter else { return nil }
        FilterClipboard.write(filter)
        return filter
    }

    /// ⌘X = 复制 + 删除。
    func cutSelectedFilter() -> FilterClip? {
        guard let filter = copySelectedFilter() else { return nil }
        deleteFilter(filter.id)
        return filter
    }

    /// ⌘V。落点和按 `+` 完全一致：从播放头起，落在这段时间内空着的最低层。
    ///
    /// **层号不跟着复制走**：原来那一层在另一个工程（甚至同一个工程的另一处）
    /// 可能根本不存在，硬套会凭空多出几条空行。时长和强度照抄 —— 那才是用户
    /// 「调好了想再来一份」要的东西。
    @discardableResult
    func pasteFilter() -> UUID? {
        guard let payload = FilterClipboard.read() else { return nil }
        let start = max(0, clock.displayTime)
        let layer = state.lowestFreeFilterLayer(start: start, end: start + payload.duration)
        let filter = FilterClip(
            preset: payload.preset, strength: payload.strength,
            timelineStart: start, duration: payload.duration, layer: layer
        )
        perform(rebuildsPreview: false) { $0.filters.append(filter) }
        selectFilter(filter.id)
        return filter.id
    }

    // MARK: - 删

    func deleteFilter(_ id: UUID) {
        perform(rebuildsPreview: false) { state in
            state.filters.removeAll { $0.id == id }
            // 空出来的层号收拢：相对顺序不变，所以画面不跳（见 compactFilterLayers）。
            state.compactFilterLayers()
        }
        // 选中态不用在这儿手动清：段一没，`state` 的 didSet 里那道
        // `pruneFilterSelection` 会顺着写入把它摘掉（同转场那条口径）。
    }

    // MARK: - 拖动

    /// 滤镜块的拖动会话。
    ///
    /// 与形状/文字那两条同构，只有一处不同：**障碍是同一层上的其他滤镜段**。
    /// 叠加靠的是分层，同一行里两段叠在一起只会互相盖住，看都看不清 ——
    /// 所以同层碰撞照样要挡，跨层随便叠。
    ///
    /// 滤镜段进不了框选（`EditSelection` 里它和标记、转场同族），所以永远不会
    /// 有伙伴跟着走，成员表里只有它自己。
    func filterDragPlan(filterID id: UUID) -> ClipDragPlan? {
        guard let filter = state.filters.first(where: { $0.id == id }) else { return nil }
        let span = TimelineSpan(start: filter.timelineStart, end: filter.timelineEnd)
        // 拖选中的一段 = 框选 / ⌘A 选中的那一片一起走（2026-09-25）：选中的滤镜段都是成员，
        // 同一层上**没在动**的段才是障碍；剪辑 / 形状 / 文字 / cue 的伙伴和别的块起手时同一份规则。
        let anchored = selectedFilterIDs.contains(id)
        let moving: Set<UUID> = anchored ? selectedFilterIDs.union([id]) : [id]
        let members = state.filters.filter { moving.contains($0.id) }.map { member -> ClipDragPlan.Member in
            let obstacles = state.filters
                .filter { $0.layer == member.layer && !moving.contains($0.id) }
                .map { TimelineSpan(start: $0.timelineStart, end: $0.timelineEnd) }
                .sorted { $0.start < $1.start }
            return ClipDragPlan.Member(
                id: member.id, span: TimelineSpan(start: member.timelineStart, end: member.timelineEnd),
                obstacles: obstacles, kind: .filter
            )
        }
        let clipIDs = state.draggingClipIDs(
            seed: anchored ? selectedClipIDs : [], linkage: linkageEnabled, magnetPinsMainTrack: magnetEnabled
        )
        let companions = movingCompanions(draggedID: id, movingClipIDs: clipIDs)
        return ClipDragPlan(
            draggedID: id,
            draggedSpan: span,
            members: members + ClipDragPlan.clipMembers(in: state, movingIDs: clipIDs),
            candidates: snapCandidates(moving: moving.union(clipIDs).union(companions.ids)),
            magnet: nil
        ).adding(shapes: companions.shapes, texts: companions.texts, cues: companions.cues, filters: [])
    }

    // MARK: - 查询

    /// 此刻生效的滤镜，按生效顺序（层号小的在前、先作用）。
    func activeFilters(at time: Double) -> [FilterClip] {
        state.activeFilters(at: time)
    }
}
