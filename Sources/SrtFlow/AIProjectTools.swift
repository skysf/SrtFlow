import Foundation
import ImageIO
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - 工具：状态、打开文件夹、打开 / 新建 / 保存工程、撤销、播放头
//
// 管什么：这几样工具在 App 里真正怎么做。都在主线程上跑（`AIToolRouter` 排好队交过来）。
// 不管什么：参数表和说明（SrtFlowMCPKit/MCPProjectTools.swift）、时间线上的活（AITimelineTools）。
//
// 打开 / 新建工程会碰到「当前工程从没存过、又剪了东西」：界面上那条路弹一个模态框问要不要存，
// AI 这条路**不许弹模态框**（用户在对话框那边，看不见也点不着，调用就一直挂着），也不问（方案第 34 条：只有删文件才问）：
// 先把它存进 `<起点>/SrtFlow/工程`（撞名加编号）再换，结果里写存到了哪。新建 / 另存撞了同名文件同样加编号，从不覆盖。

@MainActor
enum AIProjectTools {
    static func status(_ project: VideoEditProject) -> AIToolResult {
        let workspace = AIWorkspace.shared
        let session = AISession.shared
        var projectInfo: [String: JSONValue] = [
            "name": .string(project.projectName),
            "saved_to_disk": .bool(project.documentURL != nil),
            "unsaved_changes": .bool(project.hasUnsavedChanges),
            "duration": AIFormat.seconds(project.state.duration),
            "clips": .number(Double(project.state.allClips.count)),
            "empty": .bool(project.state.isEmpty)
        ]
        if let url = project.documentURL { projectInfo["path"] = .string(url.path) }
        if !project.missingMedia.isEmpty {
            projectInfo["missing_media"] = .array(project.missingMedia.map { .string($0.path) })
        }
        var result: [String: JSONValue] = [
            "app_version": .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"),
            "project": .object(projectInfo),
            "folders": .array(workspace.folders.map { .string($0.path) }),
            "output_folder": .string(workspace.outputFolder(.exports, project: project).path),
            "jobs": .array(AIJobs.shared.running.map { AIJobs.shared.json($0) }),
            "stopped_by_user": .bool(session.phase == .stopped),
            "view": .string(session.viewMode.rawValue)
        ]
        // SrtFlow 自己的声音（本机的 Kokoro）下没下（方案第 50 条：让 AI 知道有这回事）。
        switch KokoroVoicePack.shared.state {
        case .installed: result["srtflow_voices"] = "downloaded"
        case .downloading(let fraction): result["srtflow_voices"] = .string("downloading \(Int(fraction * 100))%")
        case .notInstalled, .failed: result["srtflow_voices"] = .string("not downloaded (add_voiceover download_voices=true, \(AIVoiceRole.kokoroDownloadSize))")
        }
        if #available(macOS 26.0, *) {
            result["subtitle_generation"] = .bool(SpeechTranscriptionService.isAvailable)
        } else {
            result["subtitle_generation"] = false
        }
        // 配了 fal（generate_media 在清单里）：告诉 AI 今天还剩多少额度、每种事默认用哪个模型。
        if let generation = FalGenerateTool.statusJSON() { result["generation"] = generation }
        return .ok(.object(result))
    }

    // MARK: 文件夹

    static func openFolder(_ args: AIToolArguments, _ project: VideoEditProject) async throws -> AIToolResult {
        // 用户说的文件夹（path），或者访达里此刻选中的东西（from_finder，方案第 22 条）。
        var selected: [URL]?
        let folder: URL
        if try args.bool("from_finder") ?? false {
            let items: [URL]
            do {
                items = try await AIFinderSelection.read()
            } catch let failure as AIFinderSelection.Failure {
                throw AIToolError(failure.message)
            }
            let pick = AIFinderSelection.workspace(for: items) { url in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
            }
            folder = pick.folder
            selected = pick.only
        } else {
            guard let path = try args.string("path") else { throw AIToolError("Pass path (the folder the user named), or from_finder=true.") }
            folder = AIFormat.url(fromPath: path, relativeTo: AIWorkspace.shared.current)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AIToolError("\(folder.path) is not a folder on this Mac.")
        }
        let maxFiles = min(max(try args.int("max_files") ?? 400, 1), 2000)
        AIWorkspace.shared.register(folder)
        // 只列选中的时先扫全（上限放宽），再挑出选中的：不然大文件夹里选中的可能在上限之外。
        var scan = AIMediaScan.scan(folder, maxFiles: selected == nil ? maxFiles : 20_000)
        if let selected {
            let picked = scan.entries.filter { AIFinderSelection.isSelected($0.url, among: selected) }
            scan.truncated = picked.count > maxFiles
            scan.entries = Array(picked.prefix(maxFiles))
        }
        var files: [JSONValue] = []
        var counts: [String: Int] = [:]
        for entry in scan.entries {
            counts[entry.kind.rawValue, default: 0] += 1
            files.append(await describe(entry, relativeTo: folder, project: project))
        }
        var result: [String: JSONValue] = [
            "folder": .string(folder.path),
            "output_folder": .string(AIWorkspace.shared.outputFolder(.exports, project: project)
                .deletingLastPathComponent().path),
            "counts": .object(counts.mapValues { .number(Double($0)) }),
            "files": .array(files)
        ]
        if scan.truncated { result["truncated"] = .string("Only the first \(maxFiles) files are listed.") }
        if let selected {
            result["from_finder"] = .string("\(selected.count) item(s) selected in Finder; only those are listed.")
        }
        if scan.hasOutputFolder { result["note"] = "The SrtFlow subfolder (earlier exports and projects) is not listed." }
        return .ok(.object(result))
    }

    /// 一个文件的样子：视频给时长、尺寸、帧率、有没有声音；音频给时长；图片给尺寸。
    private static func describe(_ entry: AIMediaScan.Entry, relativeTo folder: URL, project: VideoEditProject) async -> JSONValue {
        var object: [String: JSONValue] = [
            "path": .string(AIFormat.path(entry.url, relativeTo: folder)),
            "kind": .string(entry.kind.rawValue),
            "size_mb": .number((Double(entry.bytes) / 1_048_576 * 10).rounded() / 10)
        ]
        switch entry.kind {
        case .video:
            if let info = await project.probeVideo(entry.url) {
                object["duration"] = AIFormat.seconds(info.duration)
                object["width"] = .number(Double(info.width))
                object["height"] = .number(Double(info.height))
                object["fps"] = .number((info.frameRate * 100).rounded() / 100)
                object["has_audio"] = .bool(info.hasAudio)
            } else {
                object["unreadable"] = true
            }
        case .audio:
            if let duration = await project.audioDuration(entry.url) {
                object["duration"] = AIFormat.seconds(duration)
            } else {
                object["unreadable"] = true
            }
        case .image:
            if let source = CGImageSourceCreateWithURL(entry.url as CFURL, nil),
               let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                if let width = properties[kCGImagePropertyPixelWidth] as? Int { object["width"] = .number(Double(width)) }
                if let height = properties[kCGImagePropertyPixelHeight] as? Int { object["height"] = .number(Double(height)) }
            }
        case .subtitle, .project, .document:
            break
        }
        return .object(object)
    }

    // MARK: 工程

    static func openProject(_ args: AIToolArguments, _ project: VideoEditProject) async throws -> AIToolResult {
        let url = AIWorkspace.shared.resolve(try args.requiredString("path"))
        guard url.pathExtension.lowercased() == VideoEditProjectFile.fileExtension,
              FileManager.default.fileExists(atPath: url.path) else {
            throw AIToolError("\(url.path) is not an existing .\(VideoEditProjectFile.fileExtension) file.")
        }
        let kept = try keepUnsavedEdits(project)
        await project.openProject(at: url)
        guard project.documentURL?.standardizedFileURL.path == url.standardizedFileURL.path else {
            throw AIToolError(project.notice ?? "SrtFlow could not open \(url.lastPathComponent).")
        }
        AISession.shared.rebase(project: project)
        var result: [String: JSONValue] = [
            "opened": .string(url.path),
            "duration": AIFormat.seconds(project.state.duration),
            "clips": .number(Double(project.state.allClips.count))
        ]
        if !project.missingMedia.isEmpty {
            result["missing_media"] = .array(project.missingMedia.map { .string($0.path) })
        }
        if let kept { result["previous_project_saved_to"] = .string(kept.path) }
        return .ok(.object(result))
    }

    static func newProject(_ args: AIToolArguments, _ project: VideoEditProject) throws -> AIToolResult {
        let workspace = AIWorkspace.shared
        let folder = try args.string("folder").map { workspace.resolve($0) }
            ?? workspace.outputFolder(.projects, project: project)
        let fallbackName = workspace.current?.lastPathComponent ?? L10n("Untitled")
        let stem = ExportFileName.stem(
            from: try args.string("name") ?? fallbackName,
            droppingExtension: VideoEditProjectFile.fileExtension, fallback: fallbackName
        )
        let kept = try keepUnsavedEdits(project)
        // 撞名加编号（在存下没存过的那个之后再算，免得正好撞上它）。
        let url = ExportFileName.unoccupied(in: folder, stem: stem, pathExtension: VideoEditProjectFile.fileExtension) {
            FileManager.default.fileExists(atPath: $0.path)
        }
        project.newProject()
        guard project.documentURL == nil, project.state.isEmpty else {
            throw AIToolError(project.notice ?? "SrtFlow could not close the current project.")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard project.saveDocument(as: url) else {
            throw AIToolError(project.notice ?? "SrtFlow could not save the new project to \(url.path).")
        }
        AISession.shared.rebase(project: project)
        var result: [String: JSONValue] = ["created": .string(url.path)]
        if let kept { result["previous_project_saved_to"] = .string(kept.path) }
        return .ok(.object(result))
    }

    static func saveProject(_ args: AIToolArguments, _ project: VideoEditProject) throws -> AIToolResult {
        let requested = try args.string("path").map { path -> URL in
            var url = AIWorkspace.shared.resolve(path)
            if url.pathExtension.lowercased() != VideoEditProjectFile.fileExtension {
                url = url.appendingPathExtension(VideoEditProjectFile.fileExtension)
            }
            return url
        }
        guard requested != nil || project.isUntitled else {
            guard project.flushAutosave() else { throw AIToolError(project.notice ?? "SrtFlow could not save the project.") }
            return .ok(["saved": .string(project.documentURL?.path ?? "")])
        }
        var url = requested ?? AIWorkspace.shared.outputFolder(.projects, project: project)
            .appendingPathComponent(defaultStem(project))
            .appendingPathExtension(VideoEditProjectFile.fileExtension)
        // 撞了别的文件就加编号，从不覆盖（存回它自己原来的位置不算撞）。
        if url.standardizedFileURL.path != project.documentURL?.standardizedFileURL.path {
            url = ExportFileName.unoccupied(
                in: url.deletingLastPathComponent(), stem: url.deletingPathExtension().lastPathComponent,
                pathExtension: VideoEditProjectFile.fileExtension
            ) { FileManager.default.fileExists(atPath: $0.path) }
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard project.saveDocument(as: url) else {
            throw AIToolError(project.notice ?? "SrtFlow could not save the project to \(url.path).")
        }
        return .ok(["saved": .string(url.path)])
    }

    /// AI 改了一个**从来没存过**的工程：马上存进 `<起点>/SrtFlow/<工程>`，之后交给自动保存。
    /// 不然 App 一崩，AI 这一轮的活全丢（2026-09-27 实测：Claude 在开着的 Untitled 上改了九处，一直没存盘；
    /// 用户同意改成自动存）。撞名就换个名字、不覆盖也不问：这一步是兜底，不该打断 AI。
    static func saveIfNeverSaved(_ project: VideoEditProject, after result: AIToolResult) -> AIToolResult {
        guard project.isUntitled, !project.state.isEmpty, case .object(var payload) = result.payload else { return result }
        if let url = saveUntitled(project) {
            payload["project_saved_to"] = .string(url.path)
        } else {
            payload["warning"] = .string(
                "SrtFlow could not save this never-saved project: \(project.notice ?? "unknown error"). "
                    + "Call save_project with a path the user agrees on, or the edits are lost if SrtFlow quits."
            )
        }
        var saved = result
        saved.payload = .object(payload)
        return saved
    }

    /// 从没存过的工程存进 `<起点>/SrtFlow/<工程>`，撞名加编号。存不下回 nil（原因在 `project.notice`）。
    private static func saveUntitled(_ project: VideoEditProject) -> URL? {
        let folder = AIWorkspace.shared.outputFolder(.projects, project: project)
        let url = ExportFileName.unoccupied(
            in: folder, stem: defaultStem(project), pathExtension: VideoEditProjectFile.fileExtension
        ) { FileManager.default.fileExists(atPath: $0.path) }
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil,
              project.saveDocument(as: url) else { return nil }
        return url
    }

    /// 没存过的工程叫什么：主轨第一段素材的名字（和手动「存储为」建议的一样），没有就 Untitled。
    private static func defaultStem(_ project: VideoEditProject) -> String {
        ExportFileName.stem(from: project.state.mainClips.first?.name ?? L10n("Untitled"),
                            droppingExtension: "", fallback: L10n("Untitled"))
    }

    /// 当前工程没存过、又剪了东西（手动剪的；AI 改过的早就自动存了）：换工程之前先存下来，不问也不丢，
    /// 原来那条路也就不会弹模态框。存不下就报错、不换。返回存到了哪（没有要存的就 nil）。
    private static func keepUnsavedEdits(_ project: VideoEditProject) throws -> URL? {
        guard project.isUntitled, !project.state.isEmpty else { return nil }
        guard let url = saveUntitled(project) else {
            throw AIToolError(
                "The project open in SrtFlow was never saved and SrtFlow could not save it (\(project.notice ?? "unknown error")), "
                    + "so it is still open. Ask the user to save it in SrtFlow first."
            )
        }
        return url
    }

    // MARK: 撤销、播放头

    static func undo(_ args: AIToolArguments, _ project: VideoEditProject) throws -> AIToolResult {
        if try args.bool("round") == true {
            guard AIUndoGrouping.step(project.effectiveUndoManager, { AISession.shared.undoRound(project: project) }) else {
                throw AIToolError("There is nothing from this round of AI edits to undo.")
            }
            return .ok(["undone": "round"], changed: true)
        }
        let steps = min(max(try args.int("steps") ?? 1, 1), 50)
        guard let manager = project.effectiveUndoManager else { throw AIToolError("SrtFlow has nothing to undo.") }
        var undone = 0
        while undone < steps, manager.canUndo {
            manager.undo()
            undone += 1
        }
        guard undone > 0 else { throw AIToolError("SrtFlow has nothing to undo.") }
        return .ok(["undone_steps": .number(Double(undone))], changed: true)
    }

    /// 看得见还是后台（方案第 7 条）。
    static func setView(_ args: AIToolArguments) throws -> AIToolResult {
        guard let raw = try args.choice("mode", from: ["visible", "background"]),
              let mode = AISession.ViewMode(rawValue: raw) else { throw AIToolError("mode is required: visible or background.") }
        AISession.shared.setViewMode(mode)
        return .ok([
            "view": .string(mode.rawValue),
            "note": .string(mode == .visible
                ? "SrtFlow comes forward when you start a round of edits and shows each change."
                : "SrtFlow stays where it is and does not follow your edits; they still land in the project and can be undone.")
        ])
    }

    static func seek(_ args: AIToolArguments, _ project: VideoEditProject) throws -> AIToolResult {
        let time = min(max(try args.requiredDouble("time"), 0), project.state.duration)
        AIEditorPresenter.reveal(.init(time: time), project: project, always: true)
        return .ok(["playhead": AIFormat.seconds(time)])
    }
}
