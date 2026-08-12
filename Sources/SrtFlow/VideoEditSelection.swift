import Foundation

// 编辑器里的四类选择：剪辑、形状标注、字幕 cue、轨道块上的标记。
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
// 二、标记为什么仍然对所有人互斥：它的互斥不是为了画框，是为了**删除键**。
// ⌫ 只有一个统一入口（`VideoEditProject.deleteSelected`），"选中的是标记" 和
// "选中的是整段" 必须互斥，否则点了段上的标记再按 ⌫，删掉的会是整段素材。
// 框选也一样：`selectBox` 无论框到什么都把标记选择清掉。
//
// 字段一律 `private(set)`，唯一的改法是下面几个 mutating 方法，所以「加一类
// 选择忘了清另一类」在类型层面就不可能发生。
//
// 长期约束见 docs/architecture/subtitle-track-visibility-and-layout.md
// 与 docs/architecture/timeline-drag-gestures.md（框选那一节）。
// 纯值逻辑，checks/ProjectFile 编进去做守卫。

struct EditSelection: Equatable {
    private(set) var clipIDs: Set<UUID> = []
    private(set) var shapeIDs: Set<UUID> = []
    private(set) var subtitleCueIDs: Set<UUID> = []
    private(set) var markerRef: ClipMarkerRef?

    /// 前三类选中项的总数。标记不算 —— 它从不和别人共存。
    var count: Int { clipIDs.count + shapeIDs.count + subtitleCueIDs.count }

    var isEmpty: Bool { count == 0 && markerRef == nil }

    // MARK: - 预览上那套框的归属
    //
    // 三类加起来只有一个选中项时才有主角。这是「预览上最多一套框」的**唯一**
    // 判据 —— 别在预览层各自再写一遍「要是还选着别的就不画」，写两遍迟早分叉。

    var soleClipID: UUID? { count == 1 ? clipIDs.first : nil }
    var soleShapeID: UUID? { count == 1 ? shapeIDs.first : nil }
    var soleSubtitleCueID: UUID? { count == 1 ? subtitleCueIDs.first : nil }

    // MARK: - 点选：一类生效，其余三类清空

    /// 选剪辑：非空就清掉其余三类。
    ///
    /// 空集合**不**清另外几类 —— 「取消剪辑选择」和「改选别的东西」是两件事，
    /// 加选/减选（⌘点）减到空时不该顺手把无关的选择也抹掉。
    mutating func selectClips(_ ids: Set<UUID>) {
        clipIDs = ids
        guard !ids.isEmpty else { return }
        shapeIDs = []
        subtitleCueIDs = []
        markerRef = nil
    }

    /// 选形状：非空就清掉其余三类。
    mutating func selectShapes(_ ids: Set<UUID>) {
        shapeIDs = ids
        guard !ids.isEmpty else { return }
        clipIDs = []
        subtitleCueIDs = []
        markerRef = nil
    }

    /// 选字幕 cue：非空就清掉其余三类。
    mutating func selectSubtitleCues(_ ids: Set<UUID>) {
        subtitleCueIDs = ids
        guard !ids.isEmpty else { return }
        clipIDs = []
        shapeIDs = []
        markerRef = nil
    }

    /// 单选门面（点一下轨道上的形状 / cue 就是它）。
    mutating func selectShape(_ id: UUID?) {
        selectShapes(id.map { [$0] } ?? [])
    }

    mutating func selectSubtitleCue(_ id: UUID?) {
        selectSubtitleCues(id.map { [$0] } ?? [])
    }

    /// 选标记：非 nil 就清掉其余三类。
    ///
    /// 尤其要清掉**标记所在那一段**的剪辑选择：点标记之前多半刚点过那一段，
    /// 两个都留着的话 ⌫ 到底删谁全看 `deleteSelected` 的分支顺序，是纯运气。
    mutating func selectMarker(_ ref: ClipMarkerRef?) {
        markerRef = ref
        guard ref != nil else { return }
        clipIDs = []
        shapeIDs = []
        subtitleCueIDs = []
    }

    // MARK: - 框选：三类一次落定

    /// 鼠标拉框选出来的结果。**混选只能从这一个入口进来** —— 点选那几个方法
    /// 的互斥一条都没松，所以「哪里会产生混选」永远只有这一处答案。
    ///
    /// 标记无条件清掉，哪怕框是空的：框选是一次明确的「重新指定选中项」，
    /// 留着标记的话 ⌫ 会走进标记分支，删掉一枚用户早就不看着的标记。
    mutating func selectBox(clips: Set<UUID>, shapes: Set<UUID>, cues: Set<UUID>) {
        clipIDs = clips
        shapeIDs = shapes
        subtitleCueIDs = cues
        markerRef = nil
    }

    /// 四类一起清（点预览空白、切工程）。
    mutating func clear() {
        clipIDs = []
        shapeIDs = []
        subtitleCueIDs = []
        markerRef = nil
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
}
