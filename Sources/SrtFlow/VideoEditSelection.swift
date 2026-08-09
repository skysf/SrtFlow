import Foundation

// 编辑器里的三类选择：剪辑、形状标注、字幕 cue。
//
// 它们**三者互斥** —— 预览上每一类都会画自己的框（剪辑/形状是变换框，
// 字幕是布局拖框），同时出现两套框，用户既不知道拖谁，把手还会互相压住。
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

    /// 选剪辑：非空就清掉形状与字幕 cue。
    ///
    /// 空集合**不**清另外两类 —— 「取消剪辑选择」和「改选别的东西」是两件事，
    /// 加选/减选（⌘点）减到空时不该顺手把无关的选择也抹掉。
    mutating func selectClips(_ ids: Set<UUID>) {
        clipIDs = ids
        guard !ids.isEmpty else { return }
        shapeID = nil
        subtitleCueID = nil
    }

    /// 选形状：非 nil 就清掉剪辑与字幕 cue。
    mutating func selectShape(_ id: UUID?) {
        shapeID = id
        guard id != nil else { return }
        clipIDs = []
        subtitleCueID = nil
    }

    /// 选字幕 cue：非 nil 就清掉剪辑与形状。
    mutating func selectSubtitleCue(_ id: UUID?) {
        subtitleCueID = id
        guard id != nil else { return }
        clipIDs = []
        shapeID = nil
    }

    /// 三类一起清（点预览空白、切工程）。
    mutating func clear() {
        clipIDs = []
        shapeID = nil
        subtitleCueID = nil
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
}
