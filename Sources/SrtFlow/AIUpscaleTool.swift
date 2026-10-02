import CoreGraphics
import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - 工具：upscale_clip（把一段的原片送 fal 放大，做完直接换源）
//
// 管什么：参数读成一次 upscale —— 和面板同一份数（UpscalePanelModel 算范围、估价、档位可不可用），起 `UpscaleJob`
//（花钱按每日上限把关：额度内直接做、超了在提示条上问，FalJobGate）→ **回任务号**（一次 1–5 分钟），`get_job` 带阶段；
// 做完**直接换源**（2026-10-02 用户定：AI 起的不弹对比窗口，做完就换、一步撤销；用户随时右键「Compare with Original…」/「Revert」），
// 任务的结局带 replaced_ids / file / 尺寸 / 钱。换源是异步落账：那一下自己包一层 `AIUndoGrouping.step`（scripts/check-mcp.sh 钉着）。
// 不管什么：裁 / 传 / 下 / 封声（UpscalePipeline）、换源的规则（VideoEditClipUpscale）、钱怎么问（FalJobGate）、说明文字（MCPGenerationTools）。

@MainActor
enum AIUpscaleTool {
    static func upscale(_ args: AIToolArguments, _ project: VideoEditProject) throws -> AIToolResult {
        let store = FalSettingsStore.shared
        // 小程序没配 Key 就不列这个工具，但客户端可能缓存着旧清单：这里再认一次。
        guard store.hasKey else { throw AIToolError(FalError.noKey.message) }
        let state = project.state
        let ids = AIShortIDs(state: state)
        let id = try ids.resolve(try args.requiredString("clip_id"))
        guard let clip = state.clip(with: id) else {
            throw AIToolError("\(ids.short(id)) is not a clip; only video clips can be upscaled.")
        }
        guard !clip.isAudioOnly, !clip.isStillImage, let model = UpscalePanelModel(project: project, clipID: id) else {
            throw AIToolError("\(clip.name) is \(clip.isAudioOnly ? "audio" : "a still image"); only video clips can be upscaled.")
        }
        if let running = UpscaleActivity.shared.job(forOriginal: model.originalURL), case .running = running.state {
            throw AIToolError("\(model.originalURL.lastPathComponent) is already being upscaled; wait for that job with get_job.")
        }

        let tierID = try args.choice("tier", from: MCPVocabulary.upscaleTiers) ?? AIUpscaleNames.defaultTierID
        guard let tier = AIUpscaleNames.tier(tierID) else { throw AIToolError("Unknown tier \(tierID).") }
        let target = try args.choice("target", from: MCPVocabulary.upscaleTargets).flatMap(AIUpscaleNames.target) ?? model.defaultTarget
        let choice = try args.choice("range", from: MCPVocabulary.upscaleRanges).flatMap(AIUpscaleNames.range) ?? model.defaultChoice
        guard model.targetApplies(target) else {
            throw AIToolError(
                "\(clip.name) is \(model.originalInfo.resolutionLabel), already at or above \(target.label) on its short side; nothing to upscale."
            )
        }
        guard let row = model.rows(choice: choice, target: target).first(where: { $0.id == tier.id }) else {
            throw AIToolError("Unknown tier \(tierID).")
        }
        if let reason = row.unavailableReason {
            throw AIToolError("\(tier.title) \(tier.detail) cannot take this range: \(reason). Pick another tier or a shorter range.")
        }
        let request = model.request(choice: choice, target: target, tier: tier)

        // 任务：UpscaleJob 跑，AIJobs 里登记一条给 get_job 看（阶段、在等用户、取消）。
        let job = UpscaleJob(
            request: request, clipIDs: request.range.coveredClipIDs, projectGeneration: project.documentGeneration, title: clip.name,
            approval: .dailyLimit(project: project)
        )
        let aiJob = AIJobs.shared.start(
            .upscale, progress: { nil },
            liveDetail: { [weak job] in
                if case .running(let progress)? = job?.state { return progress.json() }
                return [:]
            },
            waitingForUser: { [weak job] in job?.waiting },
            cancel: { [weak job] in
                if let job { UpscaleActivity.shared.remove(job) }
            }
        )
        job.onFinished = { finished in land(finished, aiJob: aiJob, project: project) }
        job.onEnded = { ended in settle(ended, aiJob: aiJob) }
        UpscaleActivity.shared.add(job, opensCompare: false)

        var result: [String: JSONValue] = [
            "status": "started", "job_id": .string(aiJob.id), "clip_id": .string(ids.short(id)),
            "tier": .string(tier.id), "target": .string(AIUpscaleNames.name(of: target)), "range": .string(AIUpscaleNames.name(of: choice)),
            "source_size": .string(model.originalInfo.resolutionLabel), "output_size": .string(sizeLabel(row.outputSize)),
            "seconds_sent": AIFormat.seconds(request.range.duration),
            "clips_to_replace": .array(request.range.coveredClipIDs.map { .string(ids.short($0)) }),
            "estimated_cost_usd": FalGenerateTool.money(request.estimate),
            "daily_limit_usd": .number(store.dailyLimit), "spent_today_usd": FalGenerateTool.money(store.spentToday()),
            "next_step": .string(
                "Tell the user it costs about \(FalMoney.text(request.estimate)) and takes about \(FalJobProgress.minutes(tier.typicalSeconds)) min. "
                    + "Wait with get_job; if it shows waiting_for_user, tell the user what it says. When it is done the clips are already "
                    + "replaced (replaced_ids); the original file stays and the user can compare or revert from the clip's context menu."
            )
        ]
        if choice == .thisClip, let longer = model.longerElsewhere {
            result["note"] = .string(String(
                format: "Another clip uses %.1f s of this file; range=longest would cover both places in one job.", longer.duration
            ))
        }
        return .ok(.object(result))
    }

    // MARK: 结局

    /// 做完：换源（一步撤销）、选中换了的段、没存过的工程存一下、结局记给 AI 的任务；这一行从状态行上拿掉（AI 会告诉用户）。
    private static func land(_ finished: UpscaleJob, aiJob: AIJobs.Job, project: VideoEditProject) {
        defer { UpscaleActivity.shared.remove(finished) }
        guard let outcome = finished.outcome else { return }
        guard finished.projectGeneration == project.documentGeneration else {
            AIJobs.shared.finish(
                aiJob, .done, message: "The upscaled file was made, but the project changed meanwhile; no clip was replaced.",
                detail: .object(["file": .string(AIWorkspace.shared.display(outcome.file)), "replaced_ids": .array([])])
            )
            return
        }
        let replacement = ClipSourceSwap.Replacement(url: outcome.file, info: outcome.info, record: outcome.record)
        // 账单几分钟后才有：查到实收再补进工程里的记录（不进撤销栈）；工程中途换了就不补。
        finished.onCostResolved = { [weak project] job in
            guard let project, let cost = job.actualCost, project.documentGeneration == job.projectGeneration else { return }
            project.recordUpscaleCost(file: outcome.file, costUSD: cost)
        }
        let done = AIUndoGrouping.step(project.effectiveUndoManager) {
            project.applyUpscale(replacement, to: project.clipIDs(usingPicture: finished.request.originalURL))
        }
        let ids = AIShortIDs(state: project.state)
        if !done.isEmpty {
            AISession.shared.noteChange()
            let first = done.compactMap { project.state.clip(with: $0) }.min { $0.timelineStart < $1.timelineStart }
            AIEditorPresenter.reveal(.init(clips: Set(done), time: first?.timelineStart), project: project)
        }
        var detail: [String: JSONValue] = [
            "replaced_ids": .array(done.map { .string(ids.short($0)) }),
            "file": .string(AIWorkspace.shared.display(outcome.file)),
            "width": .number(Double(Int(outcome.info.displaySize.width))), "height": .number(Double(Int(outcome.info.displaySize.height))),
            "duration": AIFormat.seconds(outcome.info.duration),
            "tier": .string(finished.request.tier.id),
            "cost_usd": FalGenerateTool.money(finished.actualCost ?? finished.request.estimate),
            "cost_is_estimate": .bool(finished.actualCost == nil),
            "spent_today_usd": FalGenerateTool.money(FalSettingsStore.shared.spentToday()),
            "elapsed_seconds": .number(outcome.elapsed.rounded()),
            "next_step": .string(done.isEmpty
                ? "No clip could be replaced (the range no longer covers any use of the file); the upscaled file was kept."
                : "The clips now use the upscaled file (one undo step). The original stays next to it; the user can compare or revert "
                    + "from the clip's context menu. get_timeline shows the new source_size.")
        ]
        if !outcome.audioRestored {
            detail["note"] = "The original sound could not be put back (ffmpeg is missing); the file carries whatever fal.ai returned."
        }
        let saved = AIProjectTools.saveIfNeverSaved(project, after: .ok(.object(detail), changed: !done.isEmpty))
        AIJobs.shared.finish(aiJob, .done, message: done.isEmpty ? "Upscaled; nothing replaced." : "Upscaled and replaced \(done.count) clip(s).", detail: saved.payload)
    }

    /// 没做成：把结局记给 AI 的任务（done 在 land 里记）。
    private static func settle(_ ended: UpscaleJob, aiJob: AIJobs.Job) {
        switch ended.state {
        case .failed(let message):
            AIJobs.shared.finish(aiJob, .failed, message: "Upscale failed: \(message)")
        case .cancelled:
            AIJobs.shared.finish(aiJob, .cancelled, message: "The upscale was stopped before it finished; fal.ai was asked to cancel it and nothing was charged.")
        case .declined:
            AIJobs.shared.finish(aiJob, .cancelled, message: "The user did not approve the cost, so nothing was made and nothing was charged.")
        case .running, .done:
            break
        }
    }

    private static func sizeLabel(_ size: CGSize) -> String { "\(Int(size.width.rounded()))×\(Int(size.height.rounded()))" }
}
