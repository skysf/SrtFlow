import Foundation

// 编辑器里的七类选择：剪辑、形状标注、文字标注、字幕 cue、轨道块上的标记、
// 接缝上的转场、时间轴上的滤镜段。
//
// **点选**（单击）四者互斥，**框选**（鼠标拉框）可以一次选中前三类。这条分界
// 是刻意的，理由见下面两段。
//
// 一、为什么点选还要互斥：预览上每一类都会画自己的框（剪辑/形状是变换框，
// 字幕是布局拖框）。同时出现两套框，用户既不知道拖谁，把手还会互相压住。
// 框选放开之后这条约束**不是消失了，而是换了个地方守**：预览上的框只认
// `sole*` —— 三类加起来只选中一个时才有主角，多选或混选一律不画框（和以前
// 「多选剪辑时不画框」的行为一致）。所以「同时挂两套框」在类型层面仍然不可能。
//
// 二、标记和转场为什么仍然对所有人互斥：它们的互斥不是为了画框，是为了**删除键**。
// ⌫ 只有一个统一入口（`VideoEditProject.deleteSelected`），"选中的是标记" 和
// "选中的是整段" 必须互斥，否则点了段上的标记再按 ⌫，删掉的会是整段素材。
// 转场同理 —— 遮罩就压在两段片段之上，点它之前多半刚点过其中一段。
// 框选也一样：`selectBox` 无论框到什么都把标记和转场的选择清掉。
//
// 滤镜段**点选**时和别的互斥（理由同上：它和它下面那条轨在时间线上上下相邻），但
// 2026-09-25 起进框选和 ⌘A（用户拍板：所有能选中的都算）—— 那两种是明确的「重新指定
// 一片」，一片里混着滤镜按 ⌫ 就是要一起删。
//
// 字段一律 `private(set)`，唯一的改法是下面几个 mutating 方法；而「非空就清掉
// 其余各类」只在 `clearAll()` 里写一次。于是「加一类选择忘了清另一类」不靠人肉
// 复制粘贴 —— 2026-09-20 加第六类（转场）时，互斥那部分真的只改了 `clearAll()`。
//
// 长期约束见 docs/architecture/subtitle-track-visibility-and-layout.md
// 与 docs/architecture/timeline-drag-gestures.md（框选那一节）。
// 纯值逻辑，checks/ProjectFile 编进去做守卫。

struct EditSelection: Equatable {
    private(set) var clipIDs: Set<UUID> = []
    private(set) var shapeIDs: Set<UUID> = []
    private(set) var textIDs: Set<UUID> = []
    private(set) var subtitleCueIDs: Set<UUID> = []
    private(set) var markerRef: ClipMarkerRef?
    /// 选中的转场，存**出场段的 UUID**（转场写在它身上）。
    ///
    /// **不存缝下标**：拖动中磁吸会重排片段，下标当场就失效 —— 和
    /// `TransitionMaskView` 里「存下标不存片段」是同一条纪律的另一面。
    private(set) var transitionSeamID: UUID?
    /// 选中的滤镜段（可以多段：框选 / ⌘A / ⌘点，2026-09-25）。
    ///
    /// **点选**时和别的互斥：⌫ 只有 `deleteSelected` 一个入口，滤镜段和它下面的画面
    /// 在时间线上是上下相邻的两行，点滤镜之前多半刚点过某一段素材；两个都留着
    /// 的话按 ⌫ 删掉的会是整段素材。框选和 ⌘A 是明确的「重新指定一片」，可以混。
    private(set) var filterIDs: Set<UUID> = []

    /// 只选中了一段滤镜时才有主角（检查器的滤镜区、库面板「点卡片 = 换种类」都认它）。
    var soleFilterID: UUID? { filterIDs.count == 1 ? filterIDs.first : nil }

    /// 五类选中项的总数。标记和转场不算 —— 它们从不和别人共存。
    var count: Int { clipIDs.count + shapeIDs.count + textIDs.count + subtitleCueIDs.count + filterIDs.count }

    var isEmpty: Bool {
        count == 0 && markerRef == nil && transitionSeamID == nil
    }

    // MARK: - 预览上那套框的归属
    //
    // 四类加起来只有一个选中项时才有主角。这是「预览上最多一套框」的**唯一**
    // 判据 —— 别在预览层各自再写一遍「要是还选着别的就不画」，写两遍迟早分叉。

    var soleClipID: UUID? { count == 1 ? clipIDs.first : nil }
    var soleShapeID: UUID? { count == 1 ? shapeIDs.first : nil }
    var soleTextID: UUID? { count == 1 ? textIDs.first : nil }
    var soleSubtitleCueID: UUID? { count == 1 ? subtitleCueIDs.first : nil }

    // MARK: - 点选：一类生效，其余各类清空

    /// 五类一起清。**所有互斥都收在这一个方法里** —— 见文件头。
    private mutating func clearAll() {
        clipIDs = []
        shapeIDs = []
        textIDs = []
        subtitleCueIDs = []
        markerRef = nil
        transitionSeamID = nil
        filterIDs = []
    }

    /// 选剪辑：非空就清掉其余各类。
    ///
    /// 空集合**不**清另外几类 —— 「取消剪辑选择」和「改选别的东西」是两件事，
    /// 加选/减选（⌘点）减到空时不该顺手把无关的选择也抹掉。
    mutating func selectClips(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { clipIDs = []; return }
        clearAll()
        clipIDs = ids
    }

    /// 选形状：非空就清掉其余各类。
    mutating func selectShapes(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { shapeIDs = []; return }
        clearAll()
        shapeIDs = ids
    }

    /// 选文字：非空就清掉其余各类。
    mutating func selectTexts(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { textIDs = []; return }
        clearAll()
        textIDs = ids
    }

    /// 选字幕 cue：非空就清掉其余各类。
    mutating func selectSubtitleCues(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { subtitleCueIDs = []; return }
        clearAll()
        subtitleCueIDs = ids
    }

    /// 单选门面（点一下轨道上的形状 / 文字 / cue 就是它）。
    mutating func selectShape(_ id: UUID?) {
        selectShapes(id.map { [$0] } ?? [])
    }

    mutating func selectText(_ id: UUID?) {
        selectTexts(id.map { [$0] } ?? [])
    }

    mutating func selectSubtitleCue(_ id: UUID?) {
        selectSubtitleCues(id.map { [$0] } ?? [])
    }

    /// 选标记：非 nil 就清掉其余各类。
    ///
    /// 尤其要清掉**标记所在那一段**的剪辑选择：点标记之前多半刚点过那一段，
    /// 两个都留着的话 ⌫ 到底删谁全看 `deleteSelected` 的分支顺序，是纯运气。
    mutating func selectMarker(_ ref: ClipMarkerRef?) {
        guard let ref else { markerRef = nil; return }
        clearAll()
        markerRef = ref
    }

    /// 选中一条缝上的转场：非 nil 就清掉其余各类。
    ///
    /// 和标记同一个理由 —— ⌫ 只有 `deleteSelected` 一个入口。尤其要清掉**缝两侧
    /// 那两段**的剪辑选择：遮罩就压在它们之上，点遮罩之前多半刚点过其中一段，
    /// 两个都留着的话按 ⌫ 删掉的是整段素材，而不是那条转场。
    mutating func selectTransitionSeam(_ id: UUID?) {
        guard let id else { transitionSeamID = nil; return }
        clearAll()
        transitionSeamID = id
    }

    /// 选滤镜段：非空就清掉其余各类。理由见 `filterIDs` 的说明。
    mutating func selectFilters(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { filterIDs = []; return }
        clearAll()
        filterIDs = ids
    }

    /// 单选门面（点一下时间线上的滤镜段）。
    mutating func selectFilter(_ id: UUID?) {
        selectFilters(id.map { [$0] } ?? [])
    }

    // MARK: - 框选：四类一次落定

    /// 鼠标拉框选出来的结果。**混选只能从这一个入口进来** —— 点选那几个方法
    /// 的互斥一条都没松，所以「哪里会产生混选」永远只有这一处答案。
    ///
    /// 标记和转场无条件清掉，哪怕框是空的：框选是一次明确的「重新指定选中项」，
    /// 留着的话 ⌫ 会走进它们的分支，删掉一枚用户早就不看着的标记、或者清掉一条
    /// 没高亮的缝上的转场。
    mutating func selectBox(
        clips: Set<UUID>, shapes: Set<UUID>, texts: Set<UUID>, cues: Set<UUID>, filters: Set<UUID> = []
    ) {
        clipIDs = clips
        shapeIDs = shapes
        textIDs = texts
        subtitleCueIDs = cues
        filterIDs = filters
        markerRef = nil
        transitionSeamID = nil
    }

    /// 七类一起清（点预览空白、切工程）。
    mutating func clear() {
        clearAll()
    }

    // MARK: - 摘掉已经不存在的选中项

    /// 剪辑已经不在时间线上了（撤销/删除）就摘掉。
    mutating func pruneClips(keeping isValid: (UUID) -> Bool) {
        clipIDs = clipIDs.filter(isValid)
    }

    /// 形状已经不在时间线上了（撤销/删除）就摘掉。
    mutating func pruneShapes(keeping isValid: (UUID) -> Bool) {
        shapeIDs = shapeIDs.filter(isValid)
    }

    /// 文字已经不在时间线上了（撤销/删除）就摘掉。
    mutating func pruneTexts(keeping isValid: (UUID) -> Bool) {
        textIDs = textIDs.filter(isValid)
    }

    /// 选中的 cue 已经不在字幕轨里了就摘掉。
    ///
    /// 触发面比想象的宽：删字幕轨、外挂新 .srt、重新生成字幕都会把整轨换成
    /// **新的 cue 身份**，旧 ID 一个都对不上。留着的话预览会画一个锚不住任何
    /// 字幕的悬空拖框，一拖就改到别人的布局上。
    mutating func pruneSubtitleCues(isValid: (UUID) -> Bool) {
        subtitleCueIDs = subtitleCueIDs.filter(isValid)
    }

    /// 选中的标记已经不存在、或者被裁到所在段的窗口外了就摘掉。
    ///
    /// 触发面同样比想象的宽：删掉整段、撤销掉「加标记」那一步、把标记裁出窗口，
    /// 都会让引用悬空。留着的话界面上没有任何标记是高亮的，⌫ 却还会删掉一枚
    /// 看不见的标记 —— 用户只会看到「按了删除键，什么都没发生」。
    mutating func pruneMarker(isValid: (ClipMarkerRef) -> Bool) {
        guard let ref = markerRef, !isValid(ref) else { return }
        markerRef = nil
    }

    /// 选中的转场已经不在了就摘掉。触发面和标记一样宽：出场段被删、撤销掉
    /// 「设转场」那一步、缝被拖出间隙、余料被裁没了 —— 遮罩当场就不画了。
    /// 留着的话时间线上没有任何东西是高亮的，⌫ 却还会去清一条看不见的缝，
    /// 用户只会看到「按了删除键，什么都没发生」（`pruneMarker` 同一个坑）。
    mutating func pruneTransitionSeam(isValid: (UUID) -> Bool) {
        guard let id = transitionSeamID, !isValid(id) else { return }
        transitionSeamID = nil
    }

    /// 选中的滤镜段已经不在了（删除、撤销掉「加滤镜」那一步）就摘掉。
    /// 同 `pruneMarker`：留着的话时间线上没有任何东西高亮，⌫ 却还有反应。
    mutating func pruneFilter(isValid: (UUID) -> Bool) {
        filterIDs = filterIDs.filter(isValid)
    }
}
