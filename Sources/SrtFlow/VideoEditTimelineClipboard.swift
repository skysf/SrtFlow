import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 时间线的复制 / 剪切 / 粘贴（App 那一层）
//
// 管什么：系统剪贴板的读写（`TimelineClipboard`），工程上的三个动作 —— 拿选中的东西、落点从哪来（鼠标此刻 /
// 右键按下的那一处 / 播放头）、按鼠标粘时吸附、一次 `perform`、粘完选中粘出来的东西 —— 以及右键菜单的入口
// （`runClipboardCommand`）。
// 不管什么：粘到哪一行 / 哪条轨（`TimelinePaste`，纯值）、载荷长什么样（`TimelineClipboardPayload`）、
// 菜单栏那三项怎么接（`AppDelegate`：响应链的最末端，输入框里的 ⌘C 还是复制文字）、
// 指针落在时间线的哪儿（`TimelinePointer`）。
//
// 2026-09-26 用户拍板（docs/plans/2026-09-26-timeline-clipboard-and-zoom.md）；长期约束见
// docs/architecture/timeline-clipboard.md。

/// 系统剪贴板上的「一批时间线内容」。
///
/// 走**系统剪贴板**：跨工程粘贴天然成立（这个工程复制、另一个工程粘），也不用自己管生命周期。
/// 用自己的类型（`packaging/Info.plist` 里声明），**不写纯文本**：写了的话复制一段剪辑会把用户剪贴板里的
/// 字换成一串 JSON，⌘V 到别处粘出一坨乱码。2026-09-26 之前滤镜段有自己的一套（`com.srtflow.filter-clip`），
/// 并进来了 —— 同一件事两份剪贴板，迟早有人读错。
enum TimelineClipboard {
    static let typeIdentifier = "com.srtflow.timeline-items"
    static let type = UTType(exportedAs: typeIdentifier, conformingTo: .data)
    static let pasteboardType = NSPasteboard.PasteboardType(typeIdentifier)

    @discardableResult
    static func write(_ payload: TimelineClipboardPayload) -> Bool {
        guard let data = payload.encoded() else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setData(data, forType: pasteboardType)
    }

    static func read() -> TimelineClipboardPayload? {
        NSPasteboard.general.data(forType: pasteboardType).flatMap(TimelineClipboardPayload.decoded)
    }

    /// 剪贴板上有没有一批时间线内容 —— **只看类型、不读内容**：编辑菜单的亮灭每次打开菜单都要问一遍。
    static var hasContent: Bool {
        NSPasteboard.general.availableType(from: [pasteboardType]) != nil
    }
}

/// 右键菜单里的三样。
enum TimelineClipboardCommand {
    case copy, cut, paste
}

/// 右键菜单里的「剪切 / 拷贝 / 粘贴」：五种块共用一份；轨道空白处只有「粘贴」。
///
/// **是函数不是视图类型**：右键菜单的内容可能跟着块的 body 一起算，多一个视图类型就多一笔计数、
/// 块一多就是一大笔（docs/architecture/preview-perf-ratchet.md）。不挂 `.keyboardShortcut`：
/// 那三个键归编辑菜单（`AppDelegate`），挂在右键菜单上也只是提示，还可能和编辑菜单抢键。
enum TimelineClipboardMenu {
    @ViewBuilder
    static func items(_ run: @escaping (TimelineClipboardCommand) -> Void) -> some View {
        Button("Cut") { run(.cut) }
        Button("Copy") { run(.copy) }
        Button("Paste") { run(.paste) }
    }

    @ViewBuilder
    static func pasteOnly(_ paste: @escaping () -> Void) -> some View {
        Button("Paste", action: paste)
    }
}

/// 右键菜单弹在哪一块上（拷贝 / 剪切前要看它在不在选中集合里）。
enum TimelineItemRef: Equatable {
    case clip(UUID), shape(UUID), text(UUID), cue(UUID), filter(UUID)
}

/// 粘贴的落点从哪来。
enum TimelinePasteSite {
    /// ⌘V、编辑菜单：鼠标此刻在轨道区里就是鼠标那一处，不在就是播放头。
    case keyboard
    /// 右键菜单：右键按下的那一处（不在轨道区里就是播放头）。
    case contextMenu
}

extension TimelinePasteRow {
    /// 指针底下那一行 → 粘贴认的那一行。标尺不算；藏起来的行不算（不往看不见的轨上粘，同拖文件的梯子）。
    init?(_ spec: TimelineRowSpec) {
        guard !spec.isRuler, !spec.isHidden else { return nil }
        if let slot = spec.slot {
            self = .track(slot)
        } else if let layer = spec.filterLayer {
            self = .filterLayer(layer)
        } else if let row = spec.textRow {
            self = .textRow(row)
        } else if let kind = spec.subtitleKind {
            self = .subtitle(kind)
        } else if spec.isShapes {
            self = .shapes
        } else {
            return nil
        }
    }
}

@MainActor
extension VideoEditProject {
    /// 选中的东西里有能拷贝的吗（标记、转场不算：它们长在段上，跟着段走）。
    var canCopySelection: Bool { selection.count > 0 }

    /// ⌘C：选中的剪辑（链接开着时连带链接伙伴，同 ⌫）、形状、文字、字幕句、滤镜段放进剪贴板。
    @discardableResult
    func copySelection() -> Bool {
        var clips = selectedClipIDs
        if linkageEnabled {
            for id in selectedClipIDs { clips.formUnion(state.linkedClipIDs(of: id)) }
        }
        guard let payload = TimelineClipboardPayload(
            copying: state, clips: clips, shapes: selectedShapeIDs, texts: selectedTextIDs,
            cues: selectedSubtitleCueIDs, filters: selectedFilterIDs
        ) else { return false }
        return TimelineClipboard.write(payload)
    }

    /// ⌘X = 拷贝 + ⌫。删除走同一个入口：磁吸开着时主轨空档自动合拢、链接伙伴一起删、一步撤销。
    func cutSelection() {
        guard copySelection() else { return }
        deleteSelected()
    }

    /// ⌘V：剪贴板里的一批时间线内容粘到落点，一步撤销，粘完选中粘出来的东西（播放头不动）。
    /// 剪贴板里没有、或者一样都没落下去，返回 false。
    @discardableResult
    func pasteTimelineItems(at site: TimelinePasteSite) -> Bool {
        guard let payload = TimelineClipboard.read(), let first = payload.start, let last = payload.end else {
            return false
        }
        let hit = TimelinePointer.hit(site == .contextMenu ? .contextClick : .now, project: self)
        let anchor: Double
        if let hit {
            // 按鼠标粘：整批的两条边照样吸附（同拖文件，屏幕上 7pt；吸附关着时候选是空的）。
            // 按播放头粘不吸 —— 播放头就是用户定好的那一刻。
            anchor = TimelineSnap.resolve(
                proposedStart: hit.time, duration: last - first,
                candidates: snapCandidates(moving: []), pixelsPerSecond: pixelsPerSecond
            ).start
        } else {
            anchor = clock.time
        }
        let row = hit?.row.flatMap(TimelinePasteRow.init)
        var result = TimelinePasteResult()
        perform(rebuildsPreview: !payload.clips.isEmpty) { state in
            result = TimelinePaste.apply(payload, to: &state, at: anchor, pointing: row)
        }
        guard !result.isEmpty else { return false }
        applyBoxSelection(
            clips: result.clips, shapes: result.shapes, texts: result.texts, cues: result.cues, filters: result.filters
        )
        convertPastedStills(result.stillConversions)
        return true
    }

    /// 复制时静帧还没转完的图片段：照原图再转一次（同导入那条路，登记进后台任务、切工程时能取消）。
    private func convertPastedStills(_ stills: [TimelinePasteResult.StillConversion]) {
        guard !stills.isEmpty else { return }
        let generation = documentGeneration
        trackImportTask(Task { [weak self] in
            guard let self else { return }
            self.beginBackgroundImport()
            defer { self.endBackgroundImport() }
            for still in stills {
                await self.convertStillClip(still.clip, from: still.image, generation: generation)
            }
        })
    }

    /// 右键菜单的三样。拷贝 / 剪切：右键的那一块在选中集合里就作用于**整个选择**，不在就先单选它
    /// （Finder 和各家剪辑软件都是这样）。粘贴落在右键按下的那一处，和选中了谁无关；剪贴板里没东西响一声
    /// （右键菜单里的「粘贴」不按剪贴板亮灭，见方案 C9）。
    func runClipboardCommand(_ command: TimelineClipboardCommand, on item: TimelineItemRef) {
        switch command {
        case .copy, .cut:
            if !isSelected(item) { selectOnly(item) }
            if command == .copy { copySelection() } else { cutSelection() }
        case .paste:
            pasteFromContextMenu()
        }
    }

    /// 右键菜单里的「粘贴」（块上的、轨道空白处的）：落在右键按下的那一处；剪贴板里没东西响一声
    /// （右键菜单里的「粘贴」不按剪贴板亮灭，见方案 C9）。
    func pasteFromContextMenu() {
        if !pasteTimelineItems(at: .contextMenu) { NSSound.beep() }
    }

    private func isSelected(_ item: TimelineItemRef) -> Bool {
        switch item {
        case .clip(let id): return selectedClipIDs.contains(id)
        case .shape(let id): return selectedShapeIDs.contains(id)
        case .text(let id): return selectedTextIDs.contains(id)
        case .cue(let id): return selectedSubtitleCueIDs.contains(id)
        case .filter(let id): return selectedFilterIDs.contains(id)
        }
    }

    private func selectOnly(_ item: TimelineItemRef) {
        switch item {
        case .clip(let id): select(id, additive: false)
        case .shape(let id): selectShape(id, additive: false)
        case .text(let id): selectText(id, additive: false)
        case .cue(let id): selectSubtitleCue(id)
        case .filter(let id): selectFilter(id)
        }
    }
}
