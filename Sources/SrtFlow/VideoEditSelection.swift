import Foundation

// 编辑器里的四类选择：剪辑、形状标注、字幕 cue、轨道块上的标记。
//
// 它们**四者互斥** —— 预览上每一类都会画自己的框（剪辑/形状是变换框，
// 字幕是布局拖框），同时出现两套框，用户既不知道拖谁，把手还会互相压住。
// 标记加进来的理由不是画框，是**删除键**：⌫ 只有一个统一入口
//（`VideoEditProject.deleteSelected`），"选中的是标记" 和 "选中的是整段" 必须
// 互斥，否则点了段上的标记再按 ⌫，删掉的会是整段素材。
//
// 互斥性收在这个值类型里，而不是散在各个 didSet 和各个入口函数里：
// 散着写的版本漏了两条边（选 cue 不清形状、选形状不清 cue），先点形状再点
// cue 就能同时看到两套框（PR#22 复审 P2）。字段一律 `private(set)`，
// 唯一的改法是下面几个 mutating 方法，所以「加一类选择忘了清另一类」在
// 类型层面就不可能发生。
//
// 长期约束见 docs/architecture/subtitle-track-visibility-and-layout.md。
// 纯值逻辑，checks/ProjectFile 编进去做守卫。

struct EditSelection: Equatable {
    private(set) var clipIDs: Set<UUID> = []
    private(set) var shapeID: UUID?
    private(set) var subtitleCueID: UUID?
    private(set) var markerRef: ClipMarkerRef?

    /// 选剪辑：非空就清掉其余三类。
    ///
    /// 空集合**不**清另外几类 —— 「取消剪辑选择」和「改选别的东西」是两件事，
    /// 加选/减选（⌘点）减到空时不该顺手把无关的选择也抹掉。
    mutating func selectClips(_ ids: Set<UUID>) {
        clipIDs = ids
        guard !ids.isEmpty else { return }
        shapeID = nil
        subtitleCueID = nil
        markerRef = nil
    }

    /// 选形状：非 nil 就清掉其余三类。
    mutating func selectShape(_ id: UUID?) {
        shapeID = id
        guard id != nil else { return }
        clipIDs = []
        subtitleCueID = nil
        markerRef = nil
    }

    /// 选字幕 cue：非 nil 就清掉其余三类。
    mutating func selectSubtitleCue(_ id: UUID?) {
        subtitleCueID = id
        guard id != nil else { return }
        clipIDs = []
        shapeID = nil
        markerRef = nil
    }

    /// 选标记：非 nil 就清掉其余三类。
    ///
    /// 尤其要清掉**标记所在那一段**的剪辑选择：点标记之前多半刚点过那一段，
    /// 两个都留着的话 ⌫ 到底删谁全看 `deleteSelected` 的分支顺序，是纯运气。
    mutating func selectMarker(_ ref: ClipMarkerRef?) {
        markerRef = ref
        guard ref != nil else { return }
        clipIDs = []
        shapeID = nil
        subtitleCueID = nil
    }

    /// 四类一起清（点预览空白、切工程）。
    mutating func clear() {
        clipIDs = []
        shapeID = nil
        subtitleCueID = nil
        markerRef = nil
    }

    /// 剪辑已经不在时间线上了（撤销/删除）就摘掉。
    mutating func pruneClips(keeping isValid: (UUID) -> Bool) {
        clipIDs = clipIDs.filter(isValid)
    }

    /// 选中的 cue 已经不在字幕轨里了就摘掉。
    ///
    /// 触发面比想象的宽：删字幕轨、外挂新 .srt、重新生成字幕都会把整轨换成
    /// **新的 cue 身份**，旧 ID 一个都对不上。留着的话预览会画一个锚不住任何
    /// 字幕的悬空拖框，一拖就改到别人的布局上。
    mutating func pruneSubtitleCue(isValid: (UUID) -> Bool) {
        guard let id = subtitleCueID, !isValid(id) else { return }
        subtitleCueID = nil
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
