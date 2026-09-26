import Foundation

// MARK: - 段的显隐（快捷键 V）
//
// 隐藏有**两级**，互不覆盖：
//
// - 整轨：轨道头那只眼睛（`mainHidden` / `EditLane.isHidden`）。隐藏的轨灰显且
//   **不可编辑**。
// - 单个：选中按 V（`EditClip.isHidden`；2026-09-26 起文字 / 形状 / 滤镜段也有自己的 `isHidden`，
//   字幕单句记在 `SubtitleCompanion.hiddenCueIDs`）。
//   藏起来的灰显但**仍可编辑** —— 按完 V 还点得中它，才按得了第二下。
//
// 两级的渲染语义是同一条：**不进预览、不进成片**（剪辑连画面带声音）。进预览和成片的清单
// 只在这里算一次（`renderedTextOverlays` / `renderedShapes` / `renderedFilters`），预览和导出都读它。
// 这个文件只有纯值（自检编得动），合同见 docs/architecture/clip-visibility.md。

enum ClipVisibility {

    /// 一批段一起切显隐时，切成什么。
    ///
    /// **只要还有一个是显示的，就全部隐藏**；全都藏着了才全部放出来。逐个翻转是
    /// 错的：一批里有藏有显时按一下 V，用户会看到一半藏起来、另一半冒出来，
    /// 再按一下又换一批 —— 永远回不到「全显示」。
    ///
    /// 一批里可以混着剪辑、文字、形状、滤镜段、字幕句（框选、⌘A 都能一次选中几类）：一起算。
    static func nextHidden(for ids: Set<UUID>, in state: TimelineState) -> Bool {
        state.allClips.contains { ids.contains($0.id) && !$0.isHidden }
            || state.textOverlays.contains { ids.contains($0.id) && !$0.isHidden }
            || state.shapes.contains { ids.contains($0.id) && !$0.isHidden }
            || state.filters.contains { ids.contains($0.id) && !$0.isHidden }
            || state.allSubtitleCues.contains { ids.contains($0.id) && !state.isSubtitleCueHidden($0.id) }
    }

    /// 真正会进预览 / 成片的段。
    ///
    /// **整轨那一级不在这里判**（调用方先滤掉隐藏的轨）：一个函数只回答一个
    /// 问题，混在一起的话「轨没隐藏但段隐藏了」这种组合会变成两处各判一半。
    static func visible(_ clips: [EditClip]) -> [EditClip] {
        clips.filter { !$0.isHidden }
    }
}

extension TimelineState {
    /// 把一批段设成隐藏 / 显示。链接组由调用方先展开（`linkedClipIDs`）——
    /// 「链接开着时音画一起藏」是产品口径，不是模型自带的。
    mutating func setHidden(_ hidden: Bool, ids: Set<UUID>) {
        for id in ids {
            update(id) { $0.isHidden = hidden }
        }
        for index in textOverlays.indices where ids.contains(textOverlays[index].id) {
            textOverlays[index].isHidden = hidden
        }
        for index in shapes.indices where ids.contains(shapes[index].id) {
            shapes[index].isHidden = hidden
        }
        for index in filters.indices where ids.contains(filters[index].id) {
            filters[index].isHidden = hidden
        }
        let cues = Set(allSubtitleCues.map(\.id)).intersection(ids)
        if !cues.isEmpty {
            editSubtitleTracks { _, companion in
                if hidden { companion.hiddenCueIDs.formUnion(cues) } else { companion.hiddenCueIDs.subtract(cues) }
            }
        }
    }

    /// 进预览和成片的文字，按叠放序（行号小的先贴）。藏起来的不算 —— 预览叠层和导出都读这一份。
    var renderedTextOverlays: [TextOverlay] { textOverlaysInStackingOrder.filter { !$0.isHidden } }

    /// 进预览和成片的形状。藏起来的不算 —— 预览叠层和导出都读这一份。
    var renderedShapes: [ShapeAnnotation] { shapes.filter { !$0.isHidden } }

    /// 进预览和成片的滤镜段，按生效顺序（`orderedFilters`）。藏起来的不算 —— 预览的 CI 链
    /// （`activeFilters(at:)`）和导出的 lut3d 链都读这一份。
    var renderedFilters: [FilterClip] { orderedFilters.filter { !$0.isHidden } }
}
