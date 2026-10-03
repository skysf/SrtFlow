import AVFoundation
import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - 工具：record_screen（AI 自己录屏）
//
// 管什么：开始（查授权 → 挑来源 → 麦克风 → 存哪 → 起一个 AI 会话交给协调者 → **等到真开录才回来**，AI 好接着操作电脑）、
// 停止（等收尾和入轨做完直接回结局）、处置上次没收完的录制（入轨 / 只留文件 / 丢弃：丢弃先问、进废纸篓）。
// 产品口径（2026-10-03 用户拍板）见 docs/plans/2026-10-03-screen-recording-mcp.md：AI 自己选来源、**从不开系统的选择窗口**；
// 没授权时请求一次、之后只在结果里说；开录不问。
// 不管什么：怎么录（ScreenRecordingCoordinator，手动和 AI 同一条流程，差别只在 `ScreenRecordingSession`）、参数（AIScreenRecordingRequest）、
// 候选（AIScreenSources）、任务和结局（AIScreenRecordingJob）、说明文字（SrtFlowMCPKit/MCPScreenTools.swift）。

@available(macOS 15.0, *)
@MainActor
enum AIScreenRecordingTool {
    /// 最近一次 AI 起的（或接过来的）录制：还在跑的，或刚结束的那个（stop 晚到一步时拿它回结局）。
    private(set) static var current: AIScreenRecordingJob?
    /// 这次运行里请求过授权没有：没授权时**只弹一次**（用户 2026-10-03：「没有权限可以弹一次窗口」），之后只在结果里说。
    private static var requestedPermission = false

    static func run(_ args: AIToolArguments, _ project: VideoEditProject) async throws -> AIToolResult {
        let request = try AIScreenRecordingRequest.parse(args)
        switch request.action {
        case .start: return try await start(request, project)
        case .stop: return try await stop(project)
        case .resolve: return try await AIScreenRecordingLeftovers.resolve(request, args, project)
        }
    }

    /// 入轨那一下：包一步撤销（落地的时候不在用户事件里，docs/architecture/ai-control-mcp.md 第四节第 1 条）；
    /// 后台模式不选中、不挪播放头（同 AIEditorPresenter.reveal）。
    static func landing(for project: VideoEditProject) -> ScreenRecordingLanding {
        ScreenRecordingLanding(
            commit: { body in AIUndoGrouping.step(project.effectiveUndoManager, body) },
            reveals: AISession.shared.viewMode == .visible
        )
    }

    /// 挂一个新任务当「最近的那个」（AI 去停 / 处置手动的录制时也用）。
    static func adopt(_ job: AIScreenRecordingJob) { current = job }

    /// 录屏进行中别的工具做不了的事（换工程、改帧率）回这句：界面上那句「先停止录屏」AI 照做不了（MCP 第四节第 25 条的口径）。
    static let lockAdvice = "Stop it first with record_screen action=stop, or wait until it finishes (get_status shows it)."
    static var lockMessage: String { "A screen recording is running in SrtFlow, so the project cannot be switched now. \(lockAdvice)" }

    // MARK: 开始

    private static func start(_ request: AIScreenRecordingRequest, _ project: VideoEditProject) async throws -> AIToolResult {
        let coordinator = ScreenRecordingCoordinator.shared
        try await AIScreenRecordingLeftovers.ensureFree(coordinator, running: current)
        guard ScreenRecordingPermissions.screen == .authorized else { throw await permissionMissing() }
        let picked = try await AIScreenSources.preset(for: request.source)
        let microphone = try microphonePlan(request)
        let output = try outputURL(for: request, project: project)

        var isDrag = false
        var options = ScreenRecordingOptions()
        options.preset = picked.preset
        if case .drag(let ratio) = request.source {
            isDrag = true
            options.sourceKind = .region
            options.regionRatio = ratio
        }
        options.capturesSystemAudio = request.computerAudio
        options.cursor = request.cursor
        options.outputURL = output

        let job = AIScreenRecordingJob(project: project, sourceDescription: picked.description, duration: request.duration, isDrag: isDrag)
        current = job
        var plan = ScreenRecordingSession()
        plan.driver = .ai
        plan.countdownSeconds = request.countdown
        plan.addsToTimeline = request.addsToTimeline
        plan.replacesExistingOutput = false
        plan.panelPlacement = .bottomLeft
        plan.landing = landing(for: project)
        plan.observer = job

        let launch = options
        Task { @MainActor in
            var options = launch
            options.microphone = await microphone.resolve(for: job)
            // 等麦克风授权的时候被叫停了（stop / cancel_job / 横幅上的停止）：不开了。
            guard job.job.status == .running else { return }
            guard coordinator.beginAutomated(plan) else {
                job.fail("SrtFlow became busy with another screen recording before this one could start.")
                return
            }
            await coordinator.start(options: options, project: project)
        }
        await job.waitUntilUnderway(seconds: Double(request.countdown) + 15)
        return try startResult(job, file: output)
    }

    private static func startResult(_ job: AIScreenRecordingJob, file: URL) throws -> AIToolResult {
        if job.job.status == .failed { throw AIToolError(job.job.message ?? "The screen recording could not start.") }
        guard case .object(var result) = AIJobs.shared.json(job.job) else { return .ok(AIJobs.shared.json(job.job)) }
        guard job.job.status == .running else { return .ok(.object(result)) }
        result["file"] = .string(AIWorkspace.shared.display(file))
        if let waiting = job.waitingText() {
            result["next_step"] = .string("Tell the user: \(waiting) Then wait with get_job.")
        } else if job.startedAt != nil {
            result["next_step"] = .string(
                "It is recording now. Do what should be recorded, then call record_screen action=stop (it also stops after duration, "
                    + "or when the user presses Stop). SrtFlow's Stop panel is at the bottom left of the main display and invisible in "
                    + "screenshots: do not click there."
            )
        } else {
            result["next_step"] = "It has not started yet; check with get_job."
        }
        return .ok(.object(result))
    }

    /// 没授权：这次运行里第一次就请求（先删一次钉着旧签名的记录，再让系统弹授权框），之后不再弹、只说去哪开。
    /// 授权下次启动才生效（录屏实施报告门槛 1），所以要用户退出重开 SrtFlow。
    private static func permissionMissing() async -> AIToolError {
        let steps = "Ask the user to turn SrtFlow on in System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording, then "
            + "choose Quit & Reopen when macOS offers it (or quit and reopen SrtFlow). After that, open_folder / open_project again "
            + "and call record_screen again."
        guard !requestedPermission else {
            return AIToolError("SrtFlow still does not have the Screen & System Audio Recording permission. \(steps)")
        }
        requestedPermission = true
        await ScreenRecordingPermissions.requestScreenAccess()
        return AIToolError(
            "SrtFlow needs the Screen & System Audio Recording permission to record by itself; macOS just asked the user "
                + "(if no window appeared, it is in System Settings). \(steps)"
        )
    }

    // MARK: 停止

    private static func stop(_ project: VideoEditProject) async throws -> AIToolResult {
        let coordinator = ScreenRecordingCoordinator.shared
        switch coordinator.state {
        case .idle, .finished, .failed:
            // 还在等用户点麦克风授权、没交给协调者：不开了。
            if let waiting = current, waiting.job.status == .running, waiting.startedAt == nil {
                waiting.cancelBeforeStart()
                return .ok(AIJobs.shared.json(waiting.job))
            }
            // 用户先按了停止、或者 duration 到点了：把刚结束的那一段的结局给它。
            if let job = current?.job, job.status != .running { return .ok(AIJobs.shared.json(job)) }
            throw AIToolError("No screen recording is running.")
        case .partialRecovery:
            throw AIToolError(AIScreenRecordingLeftovers.waitingMessage(coordinator))
        default:
            break
        }
        let job: AIScreenRecordingJob
        if let running = current, running.isCurrentSession {
            job = running
        } else {
            // 用户手动开的那一段：结局也收给 AI，入轨那一下包 AI 的一步撤销（这一下不在用户事件里）。
            job = AIScreenRecordingJob(project: project, sourceDescription: "a recording the user started in SrtFlow")
            current = job
            coordinator.handOver(to: job, landing: landing(for: project))
        }
        await coordinator.stop()
        await AIJobs.shared.wait(for: job.job, seconds: 30)
        guard case .object(var result) = AIJobs.shared.json(job.job) else { return .ok(AIJobs.shared.json(job.job)) }
        if job.job.status == .running { result["next_step"] = "Still finishing the file; wait with get_job." }
        return .ok(.object(result))
    }

    // MARK: 麦克风、存哪

    /// 麦克风：挑设备（对不上当场报错）、看授权 —— 没问过就开录前问一次（任务在等用户），拒绝过就不录麦克风、结局里说。
    private struct MicrophonePlan {
        var device: AIScreenSourceMatch.Microphone?
        var mustAsk = false
        var note: String?

        @MainActor func resolve(for job: AIScreenRecordingJob) async -> MicrophoneConfiguration {
            if let note { job.notes.append(note) }
            guard let device else { return .disabled }
            guard mustAsk else { return .device(id: device.id) }
            job.waiting = "Allow SrtFlow to use the microphone in the macOS prompt."
            let granted = await ScreenRecordingPermissions.requestMicrophoneAccess()
            job.waiting = nil
            if !granted { job.notes.append(Self.denied) }
            return granted ? .device(id: device.id) : .disabled
        }

        static let denied = "SrtFlow is not allowed to use the microphone, so no narration track was recorded; the user can allow it in "
            + "System Settings ▸ Privacy & Security ▸ Microphone."
    }

    private static func microphonePlan(_ request: AIScreenRecordingRequest) throws -> MicrophonePlan {
        guard let query = request.microphone else { return MicrophonePlan() }
        let device = try AIScreenSourceMatch.pickMicrophone(
            query, among: AIScreenSources.microphones(), defaultID: ScreenRecordingPermissions.defaultMicrophoneID
        )
        switch ScreenRecordingPermissions.microphone {
        case .authorized: return MicrophonePlan(device: device)
        case .notDetermined: return MicrophonePlan(device: device, mustAsk: true)
        default: return MicrophonePlan(note: MicrophonePlan.denied)
        }
    }

    /// `<起点>/SrtFlow/录屏/<名字>.mov`，撞名加编号（从不覆盖，MCP 方案第 34 条；提交时又撞上了协调者也避让）。
    private static func outputURL(for request: AIScreenRecordingRequest, project: VideoEditProject) throws -> URL {
        let folder = AIWorkspace.shared.outputFolder(.recordings, project: project)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw AIToolError("SrtFlow could not create \(folder.path): \(error.localizedDescription)")
        }
        let stem = request.title ?? (ScreenRecordingCoordinator.suggestedName() as NSString).deletingPathExtension
        return ExportFileName.unoccupied(
            in: folder, stem: stem, pathExtension: "mov", exists: { FileManager.default.fileExists(atPath: $0.path) }
        )
    }
}
