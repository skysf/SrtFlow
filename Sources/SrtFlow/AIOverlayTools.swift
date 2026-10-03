import AppKit
import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - 工具：文字、滤镜、画面比例与帧率
//
// 管什么：set_text / set_filter / set_canvas 在 App 里怎么做。文字和滤镜都不进 AV 合成，
// 改它们不重建预览（`rebuildsPreview: false`，同界面上那几个入口的口径）。
// 不管什么：参数怎么落到文字上（AITextChange）、说明文字（SrtFlowMCPKit/MCPTimelineTools.swift）。

@MainActor
enum AIOverlayTools {
    // MARK: set_text

    static func setText(_ args: AIToolArguments, _ project: VideoEditProject) throws -> AIToolResult {
        let change = try AITextChange(args)
        var warnings: [String] = []
        if let font = change.font, !fontIsInstalled(font) {
            warnings.append("Font \"\(font)\" is not installed on this Mac, so the text falls back to the system font.")
        }
        let id: UUID
        if let raw = try args.string("text_id") {
            id = try AIShortIDs(state: project.state).resolve(raw)
            guard project.state.textOverlays.contains(where: { $0.id == id }) else {
                throw AIToolError("\(raw) is not a text. Call get_timeline for text ids.")
            }
            project.perform(rebuildsPreview: false) { $0.updateTextOverlay(id) { change.apply(to: &$0) } }
        } else {
            // 数字元件的字是滚出来的，不用给 text。
            let hasWords = !(change.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            guard hasWords || (change.number.map { !$0.remove } ?? false) else {
                throw AIToolError("text (or number) is required when adding a text.")
            }
            var overlay = TextOverlay(timelineStart: change.start ?? project.clock.time)
            change.apply(to: &overlay)
            id = overlay.id
            // 新字永远在最上面新开一行（同界面上的「加文字」），夹紧走 updateTextOverlay 那唯一一处。
            project.perform(rebuildsPreview: false) { state in
                overlay.row = state.textRowCount
                state.textOverlays.append(overlay)
                state.updateTextOverlay(overlay.id) { _ in }
            }
        }
        guard let overlay = project.state.textOverlays.first(where: { $0.id == id }) else {
            throw AIToolError("The text disappeared while it was being changed.")
        }
        AIEditorPresenter.reveal(.init(texts: [id], time: overlay.timelineStart + min(0.5, overlay.duration / 2)), project: project)
        // 按成片的画面排一次版：几行、有没有词被从中间折断（AI 看不见画面，只能靠这个自己改字号）。
        let canvas = VideoEditCompositionBuilder.renderSize(for: project.state)
        let layout = TextTypesetter.layout(overlay, canvas: canvas)
        if let word = AITextFit.brokenWord(in: layout, text: overlay.settledText) {
            warnings.append("On this \(Int(canvas.width))×\(Int(canvas.height)) frame \"\(word)\" does not fit on one line and is broken in the middle. Use a smaller font_size or a wider box_width.")
        }
        let block = TextRenderer.layoutFrame(overlay, canvas: canvas)
        if let out = AITextFit.overflow(of: block, canvas: canvas) {
            // x / y 是版面框的中心、框默认宽 0.8：短字放到边上要先收窄框（2026-09-29 验收：地名卡放在左边，左边出去 384 px）。
            warnings.append("On this \(Int(canvas.width))×\(Int(canvas.height)) frame the text block sticks out of the frame (\(AITextFit.describe(out))). x/y is the centre of a box box_width wide (\(String(format: "%.2f", overlay.boxWidth))): narrow box_width to put short text near an edge, move it, or use a smaller font_size.")
        }
        var result: [String: JSONValue] = [
            "text_id": .string(AIShortIDs(state: project.state).short(id)),
            "start": AIFormat.seconds(overlay.timelineStart),
            "end": AIFormat.seconds(overlay.timelineEnd),
            "x": AIFormat.seconds(overlay.centerX),
            "y": AIFormat.seconds(overlay.centerY),
            "lines": .number(Double(layout.lines.count)),
            // 文字块在画面上占哪儿（左、上、右、下，画面的比例）：和字幕、主体避开用。
            "block": .array([block.minX / canvas.width, block.minY / canvas.height,
                             block.maxX / canvas.width, block.maxY / canvas.height]
                .map { .number(($0 * 100).rounded() / 100) })
        ]
        if abs(overlay.rotationDegrees) > 0.01 { result["rotation"] = AIFormat.seconds(overlay.rotationDegrees) }
        if !warnings.isEmpty { result["warnings"] = .array(warnings.map { .string($0) }) }
        return .ok(.object(result), changed: true)
    }

    private static func fontIsInstalled(_ name: String) -> Bool {
        NSFontManager.shared.availableFontFamilies.contains(name) || NSFont(name: name, size: 12) != nil
    }

    // MARK: set_shape

    static func setShape(_ args: AIToolArguments, _ project: VideoEditProject) throws -> AIToolResult {
        let change = try AIShapeChange(args)
        let ids = AIShortIDs(state: project.state)
        let id: UUID
        if let text = try args.string("shape_id") {
            id = try ids.resolve(text)
            guard project.state.shapes.contains(where: { $0.id == id }) else { throw AIToolError("\(text) is not a shape.") }
            // 形状是叠在画面上的一层，不进合成：不用重建预览（同检查器改形状）。
            project.perform(rebuildsPreview: false) { state in state.updateShape(id) { change.apply(to: &$0) } }
        } else {
            let shape = try change.makeShape(at: project.clock.time)
            id = shape.id
            project.perform(rebuildsPreview: false) { $0.shapes.append(shape) }
        }
        guard let shape = project.state.shapes.first(where: { $0.id == id }) else {
            throw AIToolError("The shape disappeared while it was being changed.")
        }
        AIEditorPresenter.reveal(.init(shapes: [id], time: shape.timelineStart + min(0.5, shape.duration / 2)), project: project)
        return .ok(AIShapeChange.summary(shape, ids: AIShortIDs(state: project.state)), changed: true)
    }

    // MARK: set_filter

    static func setFilter(_ args: AIToolArguments, _ project: VideoEditProject) throws -> AIToolResult {
        let preset = try args.choice("preset", from: MCPVocabulary.filterPresetIDs).flatMap(FilterPreset.init(rawValue:))
        let start = try args.double("start").map { max(0, $0) }
        let duration = try args.double("duration").map { max(FilterClip.minimumDuration, $0) }
        let strength = try args.double("strength").map { min(max($0, 0), 1) }
        let hidden = try args.bool("hidden")
        let id: UUID
        if let raw = try args.string("filter_id") {
            id = try AIShortIDs(state: project.state).resolve(raw)
            guard project.state.filters.contains(where: { $0.id == id }) else {
                throw AIToolError("\(raw) is not a filter. Call get_timeline for filter ids.")
            }
            project.perform(rebuildsPreview: false) { state in
                state.updateFilter(id) { filter in
                    if let preset { filter.preset = preset }
                    if let start { filter.timelineStart = start }
                    if let duration { filter.duration = duration }
                    if let strength { filter.strength = strength }
                    if let hidden { filter.isHidden = hidden }
                }
                // 挪了之后和同一层的别的段撞了：换到这段时间里空着的最低层（同一层里两段叠着只会互相盖住）。
                if let moved = state.filters.first(where: { $0.id == id }),
                   state.filters.contains(where: { $0.id != id && $0.layer == moved.layer
                       && $0.timelineStart < moved.timelineEnd - 0.001 && moved.timelineStart < $0.timelineEnd - 0.001 }) {
                    let layer = state.lowestFreeFilterLayer(start: moved.timelineStart, end: moved.timelineEnd, ignoring: id)
                    state.updateFilter(id) { $0.layer = layer }
                }
                state.compactFilterLayers()
            }
        } else {
            guard let preset else { throw AIToolError("preset is required when adding a filter.") }
            let from = start ?? max(0, project.clock.displayTime)
            let length = duration ?? FilterClip.defaultDuration
            var filter = FilterClip(
                preset: preset, timelineStart: from, duration: length,
                layer: project.state.lowestFreeFilterLayer(start: from, end: from + length)
            )
            if let strength { filter.strength = strength }
            if let hidden { filter.isHidden = hidden }
            id = filter.id
            project.perform(rebuildsPreview: false) { $0.filters.append(filter) }
        }
        guard let filter = project.state.filters.first(where: { $0.id == id }) else {
            throw AIToolError("The filter disappeared while it was being changed.")
        }
        AIEditorPresenter.reveal(.init(filters: [id], time: filter.timelineStart), project: project)
        return .ok([
            "filter_id": .string(AIShortIDs(state: project.state).short(id)),
            "preset": .string(filter.preset.rawValue),
            "start": AIFormat.seconds(filter.timelineStart),
            "end": AIFormat.seconds(filter.timelineEnd),
            "strength": AIFormat.seconds(filter.strength)
        ], changed: true)
    }

    // MARK: set_canvas

    static func setCanvas(_ args: AIToolArguments, _ project: VideoEditProject) throws -> AIToolResult {
        let ratioText = try args.choice("ratio", from: MCPVocabulary.canvasRatios)
        let fps = try args.int("fps")
        guard ratioText != nil || fps != nil else { throw AIToolError("Pass ratio, fps, or both.") }
        if let fps, ProjectFrameRate(rawValue: fps) == nil {
            throw AIToolError("fps must be one of \(ProjectFrameRate.allCases.map { String($0.fps) }.joined(separator: ", ")).")
        }
        // 录屏中帧率冻结（setFrameRate 那一道闸只亮一句提示、不改）：以前这里照样回成功，AI 以为改了。先挡、一样都不改。
        if let fps, fps != project.state.frameRate.fps, ScreenRecordingCoordinator.shared.isBusy {
            throw AIToolError(AIScreenRecordingTool.lockMessage("the frame rate cannot be changed now"))
        }
        if let ratioText {
            let ratio = CanvasRatio.allCases.first { ($0 == .auto ? "auto" : $0.title) == ratioText } ?? .auto
            project.setCanvasRatio(ratio)
        }
        if let fps, let rate = ProjectFrameRate(rawValue: fps) { project.setFrameRate(rate) }
        let size = VideoEditCompositionBuilder.renderSize(for: project.state)
        return .ok([
            "ratio": .string(project.state.canvasRatio == .auto ? "auto" : project.state.canvasRatio.title),
            "width": .number(Double(Int(size.width))),
            "height": .number(Double(Int(size.height))),
            "fps": .number(Double(project.state.frameRate.fps))
        ], changed: true)
    }
}
