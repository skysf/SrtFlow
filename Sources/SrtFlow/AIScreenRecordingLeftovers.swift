import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - 上次没收完的录制：报给 AI、照它说的处置
//
// 管什么：崩溃恢复发现的残留（`pendingRecovery`）和手动录制的残缺结果（`pendingPartial`）—— get_status 里怎么报、
// 开录前挡住（manifest 只有一份，开新的会覆盖它）、record_screen action=resolve 怎么做：add / keep 走恢复框、残缺框那同一份处置
// （协调者的 resolveRecovery / resolvePartial）；discard 是删文件：**先问**（同 manage_files 那一处，`AIFileTools.confirmTrash`）、
// **进废纸篓**（MCP 方案第 23 条），再让协调者把账清掉。已经提交成用户文件的不给丢弃（同恢复框）。
// 不管什么：怎么裁决（ScreenRecordingRecoveryPlan / Ledger）、开录（AIScreenRecordingTool）。

@available(macOS 15.0, *)
@MainActor
enum AIScreenRecordingLeftovers {
    /// 开录前：协调者空着、没有没了结的账。
    static func ensureFree(_ coordinator: ScreenRecordingCoordinator, running: AIScreenRecordingJob?) async throws {
        switch coordinator.state {
        case .idle, .finished, .failed:
            break
        case .partialRecovery:
            throw AIToolError(waitingMessage(coordinator))
        default:
            if let running, running.isCurrentSession {
                throw AIToolError("A screen recording is already running (job \(running.job.id)); stop it with record_screen action=stop first.")
            }
            throw AIToolError(
                "A screen recording is being set up or running in SrtFlow right now. Wait for it to finish, or stop it with "
                    + "record_screen action=stop if the user asks."
            )
        }
        guard coordinator.hasUnsettledManifest else { return }
        // 账本在、提示还没摆出来（剪辑页从没出现过，启动时的恢复没跑）：先裁决一次。
        if coordinator.pendingRecovery == nil {
            coordinator.hasAttemptedRecovery = false
            await coordinator.recoverIfNeeded()
        }
        if coordinator.pendingRecovery != nil { throw AIToolError(waitingMessage(coordinator)) }
        if coordinator.hasUnsettledManifest {
            // 账本读不出来（坏了，原样留着），或者它点名的文件在一块现在没接上的盘上（等盘回来再裁决）：都不许开新的盖掉它。
            throw AIToolError(
                "SrtFlow still holds the record of an earlier screen recording it could not settle (its files may be on a disk that is "
                    + "not connected, or the record is damaged: \(coordinator.store.fileURL.path)), so it will not start a new recording "
                    + "over it. Tell the user."
            )
        }
    }

    /// 「有一段在等决定」：AI 要先问用户、再 resolve。
    static func waitingMessage(_ coordinator: ScreenRecordingCoordinator) -> String {
        let file = (coordinator.pendingRecovery?.result.mainURL ?? coordinator.pendingPartial?.mainURL)
            .map { AIWorkspace.shared.display($0) } ?? "a recording"
        let discard = coordinator.pendingRecovery?.allowsDiscard == true ? ", or discard it" : ""
        return "A screen recording is waiting for a decision (\(file)). Ask the user whether to add it to the timeline or keep only "
            + "the file\(discard); then call record_screen action=resolve with that decision. A new recording can start after that."
    }

    /// get_status 里的 leftover：是什么、文件、多长、为什么、能怎么处置。
    static func json(_ coordinator: ScreenRecordingCoordinator) -> JSONValue? {
        let result: ScreenRecordingResult
        var object: [String: JSONValue] = [:]
        if let pending = coordinator.pendingRecovery {
            result = pending.result
            var decisions: [JSONValue] = pending.kind == .recording ? ["add", "keep"] : ["keep"]
            if pending.allowsDiscard { decisions.append("discard") }
            object["kind"] = .string(pending.kind == .recording ? "unfinished_recording" : "microphone_only")
            object["decisions"] = .array(decisions)
        } else if let partial = coordinator.pendingPartial {
            result = partial
            object["kind"] = "cut_short"
            object["decisions"] = ["add", "keep"]
        } else {
            return nil
        }
        object["file"] = .string(AIWorkspace.shared.display(result.mainURL))
        if result.duration > 0 { object["duration"] = AIFormat.seconds(result.duration) }
        if let reason = result.partialReason { object["reason"] = .string(reason) }
        object["next_step"] = "Ask the user, then record_screen action=resolve decision=one of decisions."
        return .object(object)
    }

    // MARK: resolve

    static func resolve(
        _ request: AIScreenRecordingRequest, _ args: AIToolArguments, _ project: VideoEditProject
    ) async throws -> AIToolResult {
        let coordinator = ScreenRecordingCoordinator.shared
        guard let decision = request.decision else { throw AIToolError("resolve needs decision: add, keep or discard.") }
        if let pending = coordinator.pendingRecovery { return try await resolveRecovery(pending, decision, args, project) }
        if coordinator.pendingPartial != nil { return try await resolvePartial(decision, project) }
        throw AIToolError("There is no unfinished screen recording to resolve.")
    }

    private static func resolveRecovery(
        _ pending: PendingRecovery, _ decision: AIScreenRecordingRequest.Decision, _ args: AIToolArguments, _ project: VideoEditProject
    ) async throws -> AIToolResult {
        let coordinator = ScreenRecordingCoordinator.shared
        switch decision {
        case .add:
            guard pending.kind == .recording else {
                throw AIToolError(
                    "Only the microphone audio of that recording survived, so it cannot go on the timeline as a recording. "
                        + "Use keep (then add_clips the audio file if wanted) or discard."
                )
            }
            guard let result = await coordinator.resolveRecovery(.addToTimeline, landing: AIScreenRecordingTool.landing(for: project)) else {
                throw AIToolError(project.notice ?? "The recovered recording was not added to the timeline.")
            }
            let ids = AIShortIDs(state: project.state)
            let clips = project.state.allClips.filter { $0.linkGroup == pending.manifest.sessionID }
            var object = kept(result)
            object["decision"] = "add"
            object["clip_ids"] = .array(clips.map { .string(ids.short($0.id)) })
            object["next_step"] = "It is on the timeline (one undo step); check it with look."
            return .ok(.object(object), changed: true)
        case .keep:
            guard let result = await coordinator.resolveRecovery(.keepFile) else {
                throw AIToolError(project.notice ?? "The recovered recording could not be saved.")
            }
            return .ok(.object(kept(result)))
        case .discard:
            return try await discard(pending, args)
        }
    }

    /// 丢弃崩溃留下的临时文件：先问、进废纸篓（找得回来），再让协调者清账（它要删的已经不在了，只按 ledger 了结）。
    private static func discard(_ pending: PendingRecovery, _ args: AIToolArguments) async throws -> AIToolResult {
        guard pending.allowsDiscard else {
            throw AIToolError(
                "That recording is already saved as \(AIWorkspace.shared.display(pending.result.mainURL)), so discard does not delete "
                    + "it. If the user wants it gone, use manage_files to move it to the Trash."
            )
        }
        let files = pending.discardablePaths.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
        if let ask = try AIFileTools.confirmTrash(files, args: args, describing: "the unfinished screen recording") { return ask }
        var trashed: [JSONValue] = []
        for file in files {
            var resulting: NSURL?
            do {
                try FileManager.default.trashItem(at: file, resultingItemURL: &resulting)
            } catch {
                throw AIToolError("SrtFlow could not move \(file.lastPathComponent) to the Trash: \(error.localizedDescription)")
            }
            trashed.append(.string((resulting as URL?)?.path ?? file.lastPathComponent))
        }
        await ScreenRecordingCoordinator.shared.resolveRecovery(.discard)
        return .ok([
            "decision": "discard", "in_trash": .array(trashed),
            "note": "The leftover files are in the Trash; the user can put them back. File changes are not undone by undo."
        ])
    }

    /// 手动录制的残缺结果（文件早已在用户选的位置）：add 走残缺框的「加入时间线」，片段 id 照停止那一路收（临时挂一个任务）。
    private static func resolvePartial(_ decision: AIScreenRecordingRequest.Decision, _ project: VideoEditProject) async throws -> AIToolResult {
        let coordinator = ScreenRecordingCoordinator.shared
        switch decision {
        case .add:
            let job = AIScreenRecordingJob(project: project, sourceDescription: "a recording that was cut short")
            AIScreenRecordingTool.adopt(job)
            coordinator.handOver(to: job, landing: AIScreenRecordingTool.landing(for: project))
            await coordinator.resolvePartial(import: true)
            return .ok(AIJobs.shared.json(job.job))
        case .keep:
            let file = coordinator.pendingPartial.map { AIWorkspace.shared.display($0.mainURL) } ?? ""
            await coordinator.resolvePartial(import: false)
            return .ok(["decision": "keep", "file": .string(file), "next_step": "Only the file was kept; add_clips it when you need it."])
        case .discard:
            throw AIToolError(
                "That recording is already saved as a file, so discard does not delete it. If the user wants it gone, use manage_files "
                    + "to move it to the Trash."
            )
        }
    }

    private static func kept(_ result: ScreenRecordingResult) -> [String: JSONValue] {
        var object: [String: JSONValue] = [
            "decision": "keep", "file": .string(AIWorkspace.shared.display(result.mainURL)),
            "next_step": "Only the file was kept (not on the timeline); add_clips it when you need it."
        ]
        if let microphone = result.microphoneURL, microphone != result.mainURL {
            object["microphone_file"] = .string(AIWorkspace.shared.display(microphone))
        }
        return object
    }
}
