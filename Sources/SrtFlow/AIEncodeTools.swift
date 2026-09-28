import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - 工具：压缩视频、把字幕文件烧进视频、转字幕格式（不经过时间线的那三页）
//
// 管什么：compress_videos / burn_subtitles 把文件排进 App 里现成的压缩 / 烧录队列（用户在那一页看得见、能取消），
// 以用户在那一页记住的设置为底，AI 给的参数只用于这一批（`EncodeItem.ownSettings`），回任务号；
// convert_subtitles 当场做完。做出来的文件都放 `<起点>/SrtFlow/导出`，撞名加编号、从不覆盖，所以不用问
// （docs/architecture/ai-control-mcp.md 第四节第 10、24 条）。
// 不管什么：编码怎么跑（EncodeQueue）、参数怎么换算、输出怎么起名（AIEncodeOptions，纯值）、字幕怎么转（SubtitleConverter）。
//
// **不替用户开跑**：队列停着、里面有用户自己排了还没开始的，就不排 —— `start()` 会把等着的一起跑掉。

@MainActor
enum AIEncodeTools {
    static let maxVideos = 50
    static let maxSubtitleFiles = 200

    // MARK: compress_videos

    static func compress(_ args: AIToolArguments, _ project: VideoEditProject) async throws -> AIToolResult {
        let urls = try files(args, limit: maxVideos, kind: "video", accepts: MediaFileTypes.isVideo)
        if let ask = try AIWorkspace.shared.confirmReading(urls, verb: "read", args: args, project: project) {
            return ask
        }
        return try await enqueue(urls.map { ($0, nil) }, on: .compress, kind: .compress, args, project)
    }

    // MARK: burn_subtitles

    static func burnIn(_ args: AIToolArguments, _ project: VideoEditProject) async throws -> AIToolResult {
        guard let items = try args.array("items"), !items.isEmpty else { throw AIToolError("items is required.") }
        guard items.count <= maxVideos else { throw AIToolError("Burn at most \(maxVideos) videos per call.") }
        let pairs = try items.enumerated().map { index, item -> (video: URL, subtitles: URL) in
            let entry = AIToolArguments(item)
            let video = try existing(entry.requiredString("video"))
            let subtitles = try existing(entry.requiredString("subtitles"))
            guard MediaFileTypes.isVideo(video) else { throw AIToolError("items[\(index)]: \(video.lastPathComponent) is not a video.") }
            guard MediaFileTypes.isSubtitle(subtitles) else {
                throw AIToolError("items[\(index)]: \(subtitles.lastPathComponent) is not a subtitle file (.srt, .vtt, .ass, .ssa, .txt).")
            }
            return (video, subtitles)
        }
        guard Set(pairs.map(\.video.standardizedFileURL.path)).count == pairs.count else {
            throw AIToolError("The same video appears twice in items.")
        }
        // 这一批自带的字幕样式（烧录页记住的那套不动）；字幕文件里没有词的时间，逐词高亮不适用。
        var styleChange = try AISubtitleStyleChange(args)
        if styleChange?.changesHighlight == true {
            throw AIToolError("style.highlight needs word times, which subtitle files do not have. It works on the project's own subtitles (edit_subtitles).")
        }
        let fonts = await FontCatalogStore.shared.loadedFonts()
        styleChange = try styleChange?.resolvingFont(in: fonts.map(\.familyName))
        let batchStyle = styleChange.map { $0.applied(to: EncodeQueue.burnIn.burnInStyle) }
        let batchFontURL = batchStyle.flatMap { style in fonts.first { $0.familyName == style.fontName }?.fileURL }
        let all = pairs.flatMap { [$0.video, $0.subtitles] }
        if let ask = try AIWorkspace.shared.confirmReading(all, verb: "read", args: args, project: project) {
            return ask
        }
        // 字幕和烧录页同一个读法（SubtitleLoader：编码只走 TextDecoding）。
        let entries = try pairs.map { pair -> (URL, BurnInRequest?) in
            let document: SubtitleDocumentModel
            do {
                document = try SubtitleLoader.load(pair.subtitles)
            } catch {
                throw AIToolError("\(pair.subtitles.lastPathComponent) could not be read: \(error.localizedDescription)")
            }
            guard !document.cues.isEmpty else { throw AIToolError("\(pair.subtitles.lastPathComponent) has no subtitle lines.") }
            return (pair.video, BurnInRequest(
                subtitleURL: pair.subtitles, document: document, style: batchStyle, styleFontURL: batchFontURL
            ))
        }
        return try await enqueue(entries, on: .burnIn, kind: .burnIn, args, project)
    }

    // MARK: convert_subtitles

    static func convert(_ args: AIToolArguments, _ project: VideoEditProject) throws -> AIToolResult {
        let urls = try files(args, limit: maxSubtitleFiles, kind: "subtitle", accepts: MediaFileTypes.isSubtitle)
        guard let name = try args.choice("to", from: MCPVocabulary.subtitleFormats), let target = SubtitleFormat(rawValue: name) else {
            throw AIToolError("to is required: one of \(MCPVocabulary.subtitleFormats.joined(separator: ", ")).")
        }
        if let ask = try AIWorkspace.shared.confirmReading(urls, verb: "read", args: args, project: project) {
            return ask
        }
        let folder = AIWorkspace.shared.outputFolder(.exports, project: project)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let outputs = AIEncodeOptions.outputs(for: urls, in: folder, suffix: "", pathExtension: target.fileExtension) {
            FileManager.default.fileExists(atPath: $0.path)
        }
        var converted: [JSONValue] = []
        var failed: [JSONValue] = []
        for (url, output) in zip(urls, outputs) {
            do {
                let text = try SubtitleConverter.convertedContents(of: url, to: target)
                try Data(text.utf8).write(to: output, options: .withoutOverwriting)
                converted.append(["file": .string(AIWorkspace.shared.display(url)), "output": .string(output.path)])
            } catch {
                failed.append(["file": .string(AIWorkspace.shared.display(url)), "error": .string(error.localizedDescription)])
            }
        }
        var result: [String: JSONValue] = ["converted": .array(converted), "folder": .string(folder.path)]
        if !failed.isEmpty { result["failed"] = .array(failed) }
        return .ok(.object(result))
    }

    // MARK: 排队、任务号、结局

    private static func enqueue(
        _ entries: [(url: URL, burnIn: BurnInRequest?)], on queue: EncodeQueue, kind: AIJobs.Kind,
        _ args: AIToolArguments, _ project: VideoEditProject
    ) async throws -> AIToolResult {
        let runtime = try await ffmpeg()
        if kind == .burnIn, !runtime.canBurnInSubtitles {
            throw AIToolError("This copy of SrtFlow's video engine cannot burn subtitles (its ffmpeg has no libass).")
        }
        let page = kind == .burnIn ? "Burn In Subtitles" : "Compress Video"
        if !queue.isRunning, queue.items.contains(where: { $0.status == .waiting && $0.ownSettings == nil }) {
            throw AIToolError(
                "SrtFlow's \(page) page has videos the user queued but has not started, and starting the queue would start "
                    + "them too. Ask the user to start or remove them, then try again."
            )
        }
        let busy = entries.map(\.url).filter { url in queue.items.contains { $0.inputURL == url && !$0.isDone } }
        guard busy.isEmpty else {
            let names = busy.map(\.lastPathComponent).joined(separator: ", ")
            throw AIToolError("Already in SrtFlow's \(page) queue: \(names). Wait for it with get_job or cancel it first.")
        }
        let settings = AIEncodeOptions.apply(try AIEncodeOptions.parse(args), to: queue.settings)
        let folder = AIWorkspace.shared.outputFolder(.exports, project: project)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let outputs = AIEncodeOptions.outputs(
            for: entries.map(\.url), in: folder, suffix: queue.outputSuffix, pathExtension: "mp4"
        ) { url in
            FileManager.default.fileExists(atPath: url.path)
                || queue.items.contains { !$0.isDone && $0.outputURL.standardizedFileURL.path == url.standardizedFileURL.path }
        }
        let ids = zip(entries, outputs).compactMap { entry, output in
            queue.add(entry.url, output: output, settings: settings, burnIn: entry.burnIn)
        }
        queue.start()
        let job = AIJobs.shared.start(kind, progress: { progress(ids, in: queue) }, cancel: { ids.forEach(queue.cancel(id:)) })
        watch(job, ids, queue)
        return .ok([
            "job_id": .string(job.id),
            "status": "running",
            "settings": AIEncodeOptions.describe(settings),
            "outputs": .array(zip(entries, outputs).map { entry, output in
                ["file": .string(AIWorkspace.shared.display(entry.url)), "output": .string(output.path)]
            }),
            "next_step": "Call get_job with this job_id and wait_seconds 30 until the status is done."
        ])
    }

    /// 视频引擎（ffmpeg）：页面没出现过时可能还没找，这里找一下、最多等 10 秒。
    private static func ffmpeg() async throws -> FFmpegRuntime {
        let toolchain = MediaToolchain.shared
        toolchain.resolveIfNeeded()
        for _ in 0..<100 where toolchain.isResolving { try? await Task.sleep(nanoseconds: 100_000_000) }
        guard let runtime = toolchain.runtime else {
            throw AIToolError("SrtFlow's video engine (ffmpeg) is not available. \(toolchain.warning ?? "It is still starting; try again in a moment.")")
        }
        return runtime
    }

    /// 这一批的进度：跑完的（成、败、取消）算 1，正在跑的算它自己的进度，没轮到的算 0。
    private static func progress(_ ids: [EncodeItem.ID], in queue: EncodeQueue) -> Double? {
        let items = ids.compactMap { id in queue.items.first { $0.id == id } }
        guard !items.isEmpty else { return nil }
        return items.reduce(0) { $0 + ($1.isDone ? 1 : $1.progress) } / Double(items.count)
    }

    /// 队列没有完成回调：每半秒看一眼，这一批都跑完了（用户从列表里删掉的也算完）就记下结局。
    private static func watch(_ job: AIJobs.Job, _ ids: [EncodeItem.ID], _ queue: EncodeQueue) {
        Task { @MainActor in
            while job.status == .running {
                let items = ids.compactMap { id in queue.items.first { $0.id == id } }
                if items.allSatisfy(\.isDone) {
                    finish(job, items, removed: ids.count - items.count)
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private static func finish(_ job: AIJobs.Job, _ items: [EncodeItem], removed: Int) {
        let finished = items.filter { $0.status == .finished }
        let failed = items.filter { $0.status == .failed }
        var detail: [String: JSONValue] = ["outputs": .array(finished.map(describe))]
        if !failed.isEmpty {
            detail["failed"] = .array(failed.map { item in
                ["file": .string(AIWorkspace.shared.display(item.inputURL)), "error": .string(item.errorMessage ?? "unknown error")]
            })
        }
        let cancelled = items.count - finished.count - failed.count + removed
        if cancelled > 0 { detail["cancelled"] = .number(Double(cancelled)) }
        let status: AIJobs.Status = !finished.isEmpty ? .done : (failed.isEmpty ? .cancelled : .failed)
        AIJobs.shared.finish(job, status, message: status == .failed ? failed.first?.errorMessage : nil, detail: .object(detail))
    }

    /// 做好的一个：成品在哪、多大、比原来小了多少（变大了是正数）。
    private static func describe(_ item: EncodeItem) -> JSONValue {
        var object: [String: JSONValue] = [
            "file": .string(AIWorkspace.shared.display(item.inputURL)),
            "output": .string(item.outputURL.path)
        ]
        if let bytes = item.outputBytes { object["size_mb"] = .number((Double(bytes) / 1_048_576 * 10).rounded() / 10) }
        if let original = item.info?.fileBytes, original > 0 {
            object["original_mb"] = .number((Double(original) / 1_048_576 * 10).rounded() / 10)
        }
        if let saving = item.savingFraction { object["size_change"] = .string(String(format: "%+.0f%%", -saving * 100)) }
        return .object(object)
    }

    // MARK: 参数

    private static func files(
        _ args: AIToolArguments, limit: Int, kind: String, accepts: (URL) -> Bool
    ) throws -> [URL] {
        guard let paths = try args.stringArray("files"), !paths.isEmpty else { throw AIToolError("files is required.") }
        guard paths.count <= limit else { throw AIToolError("At most \(limit) files per call.") }
        var seen = Set<String>()
        return try paths.compactMap { path in
            let url = try existing(path)
            guard accepts(url) else { throw AIToolError("\(url.lastPathComponent) is not a \(kind) file.") }
            return seen.insert(url.standardizedFileURL.path).inserted ? url : nil
        }
    }

    private static func existing(_ path: String) throws -> URL {
        let url = AIWorkspace.shared.resolve(path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw AIToolError("\(path) does not exist.") }
        return url
    }
}
