import Combine
import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - 工具：导出、任务进度、取消任务
//
// 管什么：export_video 走导出面板那同一个导出器（`VideoEditExporter`），只是不弹面板：
// 文件名默认是工程名、放在打开的文件夹的 SrtFlow/导出 里，已经有同名文件就加编号（从不覆盖，所以不问，方案第 34 条）；
// 烧字幕、分辨率的口径和面板一样（烧看得见的轨；分辨率封短边、只降不升）。
// get_job / cancel_job 管所有长任务（AIJobs）。
// 不管什么：说明文字（SrtFlowMCPKit/MCPSubtitleExportTools.swift）、导出本身。

@MainActor
enum AIExportTools {
    private static var subscriptions: [String: AnyCancellable] = [:]

    static func export(_ args: AIToolArguments, _ project: VideoEditProject) async throws -> AIToolResult {
        let exporter = VideoEditExporter.shared
        guard !exporter.isExporting else {
            throw AIToolError("An export is already running. Wait for it with get_job, or cancel it first.")
        }
        guard !project.state.mainClips.isEmpty else { throw AIToolError("V1 is empty. Add clips before exporting.") }
        guard MediaToolchain.shared.runtime != nil else {
            throw AIToolError("SrtFlow's video engine is not ready yet. Try again in a moment.")
        }
        var state = project.stateForExport(selectionOnly: false)
        let audioOnly = VideoEditExportGraph.isAudioOnly(state)
        let requested = try outputURL(args, project: project, fileExtension: audioOnly ? "m4a" : "mp4")
        let output = ExportFileName.unoccupied(
            in: requested.deletingLastPathComponent(), stem: requested.deletingPathExtension().lastPathComponent,
            pathExtension: requested.pathExtension
        ) { FileManager.default.fileExists(atPath: $0.path) }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)

        var settings = exporter.settings
        if let resolution = try args.choice("resolution", from: MCPVocabulary.resolutions) {
            settings.resolution = AIEncodeOptions.resolution(resolution)
        }
        // 烧不烧和面板同一个开关：烧的是时间线上看得见的那几条轨；不烧 = 两只眼睛都关。
        var options = SubtitleExportOptions()
        options.burnIn = try args.bool("burn_subtitles") ?? true
        options.applyBurnChoice(to: &state)
        if audioOnly {
            state.subtitle = nil
            state.subtitleCompanion = nil
        }
        let fonts = await FontCatalogStore.shared.loadedFonts()
        let style = state.subtitleStyle(appWide: EncodeQueue.burnIn.burnInStyle)
        exporter.export(
            state: state, to: output, subtitleStyle: style,
            subtitleFontURL: fonts.first { $0.familyName == style.fontName }?.fileURL, settingsOverride: settings
        )
        guard exporter.isExporting else { throw AIToolError(exporter.errorMessage ?? "The export could not start.") }

        let job = AIJobs.shared.start(.export, progress: { exporter.progress }, cancel: { exporter.cancel() })
        // 结局在 isExporting 变回 false 的那一刻记下（@Published 在赋值之前发，那时成品路径 / 错误已经写好了）。
        subscriptions[job.id] = exporter.$isExporting.dropFirst().filter { !$0 }.first().sink { _ in
            MainActor.assumeIsolated {
                if exporter.finishedURL?.standardizedFileURL.path == output.standardizedFileURL.path {
                    AIJobs.shared.finish(job, .done, detail: ["path": .string(output.path)])
                } else if let error = exporter.errorMessage {
                    AIJobs.shared.finish(job, .failed, message: error)
                } else {
                    AIJobs.shared.finish(job, .cancelled)
                }
                subscriptions[job.id] = nil
            }
        }
        return .ok([
            "job_id": .string(job.id),
            "status": "running",
            "path": .string(output.path),
            "next_step": "Call get_job with this job_id and wait_seconds 30 until the status is done."
        ])
    }

    /// 给了完整路径就用它（扩展名按这次导出的类型改正）；否则 = 默认文件夹 + 名字（默认工程名）。
    private static func outputURL(_ args: AIToolArguments, project: VideoEditProject, fileExtension: String) throws -> URL {
        if let path = try args.string("path") {
            let url = AIWorkspace.shared.resolve(path)
            return url.pathExtension.lowercased() == fileExtension
                ? url : url.deletingPathExtension().appendingPathExtension(fileExtension)
        }
        let fallback = project.documentURL?.deletingPathExtension().lastPathComponent
            ?? project.state.mainClips.first?.name ?? "Timeline"
        let stem = ExportFileName.stem(
            from: try args.string("name") ?? fallback, droppingExtension: fileExtension, fallback: fallback
        )
        return AIWorkspace.shared.outputFolder(.exports, project: project)
            .appendingPathComponent(stem).appendingPathExtension(fileExtension)
    }

    // MARK: get_job / cancel_job

    static func job(_ args: AIToolArguments) async throws -> AIToolResult {
        let job = try find(args)
        if let wait = try args.double("wait_seconds"), wait > 0 {
            await AIJobs.shared.wait(for: job, seconds: wait)
        }
        return .ok(AIJobs.shared.json(job))
    }

    static func cancel(_ args: AIToolArguments) throws -> AIToolResult {
        let job = try find(args)
        AIJobs.shared.cancel(job)
        return .ok(AIJobs.shared.json(job))
    }

    private static func find(_ args: AIToolArguments) throws -> AIJobs.Job {
        let id = try args.requiredString("job_id")
        guard let job = AIJobs.shared.job(id) else {
            throw AIToolError("There is no job \(id). Jobs are forgotten when SrtFlow quits.")
        }
        return job
    }
}
