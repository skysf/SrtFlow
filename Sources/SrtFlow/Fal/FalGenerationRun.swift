import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - 一次生成怎么跑：把关花钱 → 取 Key → 提交、等、下载 → 结局
//
// 管什么：`generate_media` 起的那个任务从头到尾的过程（`AIJobs` 里的一条，`get_job` 看得到）。
// 1. **花钱的把关**（方案第 18 条）：额度内直接做；这一次会让今天超过每日上限、或者模型没登记单价，先在**顶上的提示条**上问用户
//    （`AISession.ask`：两个按钮，不弹模态框），问的时候任务是 running、带 `waiting_for_user`（AI 去转述）；用户按了「不要」或停止就结束，
//    没花钱。决定和记账在同一步里做完（中间没有 await），同时起的几个任务不会各自以为还在额度内。
// 2. 取 Key（钥匙串；ad-hoc 签名每出新版本第一次读会弹 macOS 的授权框：先在条上说一句这是什么）。
// 3. 提交 → 轮询 → 取结果 → 下载到 `SrtFlow/生成`（FalClient）；停止 / cancel_job 时替 fal 也取消。
// 4. 账：提交前先记上估算；没做出来（失败 / 取消 / 超时）就退回，已经做出来了（下载失败）不退 —— fal 已经收了钱。
// 不管什么：参数怎么读、结果怎么回（FalGenerateTool）、HTTP（FalClient）、请求体（FalInputs）。

@MainActor
final class FalGenerationRun {
    private let request: FalRequest
    private let model: FalModel
    private let body: JSONValue
    private let estimate: Double?
    private let usage: FalUsage
    private let folder: URL
    private let stem: String
    private unowned let project: VideoEditProject

    /// 在等用户点头时的那句话（给 AI 看，任务的 `waiting_for_user`）；没在等就是 nil。
    private(set) var waiting: String?
    private var job: AIJobs.Job?
    private var task: Task<Void, Never>?
    private var reserved: (amount: Double, day: Date)?
    /// fal 已经把结果给了我们（也就是已经收了钱）。
    private var resultReceived = false

    /// 同时下载的几个任务别挑到同一个文件名（挑名字和写文件之间隔着一次下载）。
    private static var claimedPaths: Set<String> = []

    init(
        request: FalRequest, model: FalModel, body: JSONValue, estimate: Double?, usage: FalUsage,
        folder: URL, stem: String, project: VideoEditProject
    ) {
        self.request = request
        self.model = model
        self.body = body
        self.estimate = estimate
        self.usage = usage
        self.folder = folder
        self.stem = stem
        self.project = project
    }

    func start() -> AIJobs.Job {
        let job = AIJobs.shared.start(
            .generate, progress: { nil }, waitingForUser: { [weak self] in self?.waiting }, cancel: { [weak self] in self?.cancel() }
        )
        self.job = job
        // 强引用：调用它的工具回了任务号就不再拿着它，任务自己得把它撑到跑完（跑完这个闭包放掉，环就解开了）。
        task = Task { @MainActor in await self.execute() }
        return job
    }

    /// 停止 / cancel_job：任务取消（在飞的请求会替 fal 也取消），挂在条上的问题收回。
    func cancel() {
        task?.cancel()
        if let job { AISession.shared.withdrawQuestions(owner: job.id) }
    }

    // MARK: 过程

    private func execute() async {
        guard let job else { return }
        let store = FalSettingsStore.shared

        // 1. 花钱的把关。
        switch store.decide(estimate: estimate) {
        case .allow:
            reserve(store)
        case .ask(let reason):
            let texts = questionTexts(reason, store)
            waiting = "SrtFlow is asking the user to approve this cost on the bar at the top of its window (it is in front now): "
                + texts.english + " Tell the user to answer there, then keep waiting with get_job."
            AITranslationReadiness.bringSrtFlowForward()
            let allowed = await AISession.shared.ask(texts.localized, allow: L10n("Allow"), decline: L10n("Not Now"), owner: job.id)
            waiting = nil
            guard allowed, !Task.isCancelled else {
                finish(.cancelled, "The user did not approve the cost, so nothing was made and nothing was charged.")
                return
            }
            reserve(store)
        }

        // 2. Key。
        let hinted = FalPromptFlag()
        let keyResult = await FalKeyCache.shared.key(willAsk: { [weak self] in
            hinted.value = true
            // AI 看 get_job 只见 running：得让它知道是 macOS 的授权框在等用户（不然它会对着一个「没动静」的任务干等）。
            self?.waiting = "macOS is asking the user, in a system dialog, whether SrtFlow may use the fal.ai key. Tell the user to click "
                + "Always Allow (a Mac login password may be needed; a new version of SrtFlow is asked once), then keep waiting with get_job."
            AISession.shared.setHint(L10n("macOS is about to ask whether SrtFlow may use your fal.ai key. Click Always Allow."))
            AITranslationReadiness.bringSrtFlowForward()
        })
        waiting = nil
        if hinted.value { AISession.shared.setHint(nil) }
        guard case .key(let key) = keyResult else {
            refund(store)
            finish(.failed, keyMessage(keyResult))
            return
        }

        // 3. 提交、等、取结果、下载。
        let client = FalClient(base: FalClient.configuredBase()) { key }
        do {
            let outcome = try await client.run(endpoint: model.endpoint, body: body, maxSeconds: request.kind.maxSeconds)
            resultReceived = true
            let media = try FalOutputs.media(from: outcome.result, kind: request.kind)
            let destination = claimDestination(extension: media.fileExtension)
            defer { Self.claimedPaths.remove(destination.path) }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try await client.download(media.url, to: destination)
            done(destination, media, store)
        } catch is CancellationError {
            refund(store)
            finish(.cancelled, "The generation was stopped before it finished; fal.ai was asked to cancel it and nothing was charged.")
        } catch let error as FalError {
            refund(store)
            finish(.failed, error.message)
        } catch let error as FalOutputError {
            finish(.failed, error.message)
        } catch {
            finish(.failed, "SrtFlow could not save the result: \(error.localizedDescription)")
        }
    }

    // MARK: 账

    private func reserve(_ store: FalSettingsStore) {
        let amount = estimate ?? 0
        store.recordSpend(amount)
        reserved = (amount, Date())
    }

    /// 没做出来才退：fal 只对做出来的收钱。已经拿到结果（后面下载 / 保存出了问题）就不退。
    private func refund(_ store: FalSettingsStore) {
        guard !resultReceived, let reserved else { return }
        store.refundSpend(reserved.amount, on: reserved.day)
        self.reserved = nil
    }

    // MARK: 结局

    private func done(_ file: URL, _ media: FalMedia, _ store: FalSettingsStore) {
        // SrtFlow 自己做的文件：AI 接着把它放上时间线时不该再问「读点名文件夹以外的文件」。
        if !AIWorkspace.shared.allowsReading(file, project: project) { AIReadGrants.shared.remember([file]) }
        var detail: [String: JSONValue] = [
            "file": .string(AIWorkspace.shared.display(file)),
            "kind": .string(request.kind.rawValue),
            "model": .string(model.title),
            "spent_today_usd": FalGenerateTool.money(store.spentToday()),
            "daily_limit_usd": .number(store.dailyLimit),
            "next_step": .string("Put it on the timeline with add_clips using file"
                + (request.kind == .music || request.kind == .soundEffect ? " (track new_audio)." : "."))
        ]
        if let estimate { detail["cost_usd"] = FalGenerateTool.money(estimate) }
        if let width = media.width, let height = media.height { detail["width"] = .number(Double(width)); detail["height"] = .number(Double(height)) }
        if let duration = media.duration { detail["duration"] = AIFormat.seconds(duration) }
        if request.kind == .textToVideo || request.kind == .imageToVideo {
            detail["note"] = .string("MiniMax H3 Max clips carry their own sound (room tone, foley, music); it plays with the clip. "
                + "Lower or mute the clip's volume (edit_clip) when you add your own music or narration.")
        }
        finish(.done, "Made \(file.lastPathComponent).", detail: .object(detail))
    }

    private func finish(_ status: AIJobs.Status, _ message: String, detail: JSONValue? = nil) {
        guard let job else { return }
        AIJobs.shared.finish(job, status, message: message, detail: detail)
    }

    // MARK: 私有

    private func claimDestination(extension pathExtension: String) -> URL {
        let url = ExportFileName.unoccupied(in: folder, stem: stem, pathExtension: pathExtension) {
            FileManager.default.fileExists(atPath: $0.path) || Self.claimedPaths.contains($0.path)
        }
        Self.claimedPaths.insert(url.path)
        return url
    }

    private func keyMessage(_ result: FalKeyStore.ReadResult) -> String {
        switch result {
        case .missing: return FalError.noKey.message
        case .needsPermission, .failed:
            return "SrtFlow could not read the fal.ai key from the macOS keychain. If macOS asked for permission, the user has to click "
                + "Always Allow (a new version of SrtFlow is asked again once). Ask the user to try again."
        case .key: return ""
        }
    }

    /// 提示条上问的话（跟着界面语言）和给 AI 的英文原话。
    private func questionTexts(_ reason: FalSpendPolicy.Reason, _ store: FalSettingsStore) -> (localized: String, english: String) {
        let summary = summaryText()
        switch reason {
        case .unknownPrice:
            return (
                String(format: L10n("fal.ai · %@ — SrtFlow does not know this model's price, so it asks each time. Allow?"), summary),
                "fal.ai · \(summary) — SrtFlow does not know this model's price, so it asks each time."
            )
        case .overLimit(let spent, let estimate, let limit):
            let total = FalMoney.text(spent + estimate)
            return (
                String(format: L10n("fal.ai · %@ — estimated cost %@. Today's spending would reach %@, over your %@ daily limit. Allow?"),
                       summary, FalMoney.text(estimate), total, FalMoney.text(limit)),
                "fal.ai · \(summary) — estimated cost \(FalMoney.text(estimate)); today's spending would reach \(total), over the user's "
                    + "\(FalMoney.text(limit)) daily limit."
            )
        }
    }

    /// 「MiniMax H3 Max · 5 s · 768P」：不带语言的几个记号，塞进哪种语言的句子里都行。
    private func summaryText() -> String {
        var parts = [model.title]
        switch request.kind {
        case .imageToVideo, .textToVideo: parts += ["\(Int(usage.seconds)) s", usage.tier ?? FalInputs.defaultResolution]
        case .music, .soundEffect: parts.append("\(Int(usage.seconds.rounded())) s")
        case .image, .voice, .voiceClone: break
        }
        return parts.joined(separator: " · ")
    }
}
