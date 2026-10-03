import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - AI 起的一段录制：任务号、录到哪了、结局怎么写
//
// 管什么：record_screen 的录制在 AIJobs 里那一条（get_job 看状态、录了几秒、在等用户做什么；cancel_job / 横幅上的停止 =
// 停下来、留着）、到点自己停（duration）、结局写给 AI（文件、片段 id、残缺的原因、下一步）、落地那一下的附带事
// （算这一轮的一处改动、没存过的工程存一下）。入轨那一次 perform 包一步撤销由会话的 landing 管（AIScreenRecordingTool 给）。
// AI 去停一段手动起的录制、去处置用户的残缺结果时，也临时挂一个它来收结局。
// 不管什么：怎么录（ScreenRecordingCoordinator）、参数（AIScreenRecordingRequest）。

@available(macOS 15.0, *)
@MainActor
final class AIScreenRecordingJob: ScreenRecordingObserver {
    private(set) var job: AIJobs.Job!
    private let project: VideoEditProject
    private let sourceDescription: String
    private let duration: Double?
    private let isDrag: Bool
    /// 在等用户做的事（允许麦克风）；nil = 没在等。拖区域的那句按协调者的状态现算（`waitingText`）。
    var waiting: String?
    /// 开录之前就知道的提醒（麦克风没授权所以没录……），写进结局。
    var notes: [String] = []
    private(set) var startedAt: Date?

    init(project: VideoEditProject, sourceDescription: String, duration: Double? = nil, isDrag: Bool = false) {
        self.project = project
        self.sourceDescription = sourceDescription
        self.duration = duration
        self.isDrag = isDrag
        job = AIJobs.shared.start(
            .screenRecording, progress: { nil },
            liveDetail: { [weak self] in self?.liveDetail() ?? [:] },
            waitingForUser: { [weak self] in self?.waitingText() },
            // 取消 = 停下来、留着：录下来的东西从不扔（docs/plans/2026-10-03-screen-recording-mcp.md 第 11 条）。
            // 只停自己这一段 —— 用户这会儿手动开的另一段不归这个任务管；还没交给协调者（在等麦克风授权）就不开了。
            cancel: { [weak self] in
                guard let self else { return }
                if self.isCurrentSession {
                    Task { @MainActor in await ScreenRecordingCoordinator.shared.stop() }
                } else if self.startedAt == nil {
                    self.cancelBeforeStart()
                }
            }
        )
    }

    /// 协调者手里的会话还是不是这个任务的。
    var isCurrentSession: Bool { ScreenRecordingCoordinator.shared.session.observer === self }

    /// 等到真开录、或者要用户动手、或者结束了（start 用：开录之后马上回去，AI 好接着操作电脑）。
    func waitUntilUnderway(seconds: Double) async {
        let deadline = Date().addingTimeInterval(seconds)
        while job.status == .running, startedAt == nil, waitingText() == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    func waitingText() -> String? {
        if let waiting { return waiting }
        if isDrag, isCurrentSession, case .choosingSource = ScreenRecordingCoordinator.shared.state {
            return "Ask the user to drag the area to record on the screen and press Record (Escape cancels)."
        }
        return nil
    }

    private func liveDetail() -> [String: JSONValue] {
        let coordinator = ScreenRecordingCoordinator.shared
        var detail: [String: JSONValue] = ["source": .string(sourceDescription)]
        guard isCurrentSession else { return detail }
        detail["state"] = .string(AIScreenRecordingWords.state(coordinator.state))
        if case .recording(let at) = coordinator.state { detail["recorded_seconds"] = .number(Date().timeIntervalSince(at).rounded()) }
        if case .countingDown(let remaining) = coordinator.state { detail["countdown"] = .number(Double(remaining)) }
        if let duration { detail["stops_after_seconds"] = .number(duration) }
        return detail
    }

    /// 没开成（协调者忙、参数在开录前才发现不对）：直接记失败。
    func fail(_ message: String) {
        AIJobs.shared.finish(job, .failed, message: message)
    }

    /// 还没交给协调者就叫停了（在等用户点麦克风授权时 stop / cancel_job）：记成取消，开录的那一步看到就不开了。
    func cancelBeforeStart() {
        waiting = nil
        AIJobs.shared.finish(job, .cancelled, message: "Stopped before recording began; nothing was recorded.")
    }

    // MARK: ScreenRecordingObserver

    func recordingStarted(session: UUID) {
        startedAt = Date()
        guard let duration else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            let coordinator = ScreenRecordingCoordinator.shared
            guard let self, self.job.status == .running, self.isCurrentSession, case .recording = coordinator.state else { return }
            await coordinator.stop()
        }
    }

    func recordingEnded(_ outcome: ScreenRecordingOutcome) {
        waiting = nil
        switch outcome {
        case .added(let result, let clipIDs):
            AISession.shared.noteChange()
            let ids = AIShortIDs(state: project.state)
            var detail = describe(result)
            detail["added_to_timeline"] = true
            detail["clip_ids"] = .array(clipIDs.map { .string(ids.short($0)) })
            detail["next_step"] = .string(
                "It is on the timeline (clip_ids: the video at the end of V1, then the microphone on its own track; one undo step). "
                    + "Check it with look; tidy it with transcribe + cut_speech, or edit_clip to trim where you switched windows."
            )
            // 没存过的工程：AI 的改动之后马上存（同路由那一处，这一下不在 AI 的调用里）。
            let saved = AIProjectTools.saveIfNeverSaved(project, after: .ok(.object(detail), changed: true))
            AIJobs.shared.finish(job, .done, message: "Recorded \(seconds(result.duration)) and added it to the timeline.", detail: saved.payload)
        case .savedOnly(let result):
            var detail = describe(result)
            detail["added_to_timeline"] = false
            detail["next_step"] = "Only the file was kept; add_clips it when you need it."
            AIJobs.shared.finish(job, .done, message: "Recorded \(seconds(result.duration)); the file is saved.", detail: .object(detail))
        case .awaitingDecision(let result):
            var detail = describe(result)
            detail["waiting_for_decision"] = true
            detail["next_step"] = "SrtFlow is asking the user whether to add it to the timeline. Tell the user, or call record_screen action=resolve decision=add or keep."
            AIJobs.shared.finish(job, .done, message: "The recording was cut short.", detail: .object(detail))
        case .nothingRecorded:
            AIJobs.shared.finish(job, .cancelled, message: "Stopped before recording began; nothing was recorded.")
        case .failed(let message):
            AIJobs.shared.finish(job, .failed, message: "The screen recording failed: \(message)")
        }
    }

    /// 结局里共有的几样：文件、多长、多大、录的是什么、残缺的原因、开录前就有的提醒。
    private func describe(_ result: ScreenRecordingResult) -> [String: JSONValue] {
        var detail: [String: JSONValue] = [
            "file": .string(AIWorkspace.shared.display(result.mainURL)),
            "duration": AIFormat.seconds(result.duration),
            "source": .string(sourceDescription)
        ]
        if result.pixelSize.width > 0 {
            detail["width"] = .number(Double(Int(result.pixelSize.width)))
            detail["height"] = .number(Double(Int(result.pixelSize.height)))
        }
        if let microphone = result.microphoneURL { detail["microphone_file"] = .string(AIWorkspace.shared.display(microphone)) }
        if result.isPartial { detail["cut_short"] = .string(result.partialReason ?? "The recording is incomplete.") }
        if !notes.isEmpty { detail["note"] = .string(notes.joined(separator: " ")) }
        return detail
    }

    private func seconds(_ value: Double) -> String { String(format: "%.1f s", value) }
}
