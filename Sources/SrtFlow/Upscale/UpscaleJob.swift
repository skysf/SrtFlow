import Foundation

// MARK: - 用户点了「开始」之后的那个任务：记账 → 取 Key → 跑流水线 → 对账实际扣费
//
// 管什么：面板起的，面板上的估价已经是用户的确认（方案第 10 条：记进 fal 的账本、超限只标红不拦），不再问；AI 起的（upscale_clip）
// 按每日上限把关、超了在提示条上问（FalJobGate，`Approval.dailyLimit`）；取 Key（钥匙串，
// 新版本第一次读会弹授权框，`keyPrompt` 让界面说一句）；跑 `UpscalePipeline`，阶段（含上传 / 下载的字节比例、这一阶段过了多久）发给界面；做完几分钟内去账单明细里
// 把实际扣费查回来（要 ADMIN 权限的 Key，查不到就只有估价）。没做出来的钱退回（照 FalGenerationRun 的规矩：拿到结果就不退）。
// 做完**不替换**：对比窗口里用户点了 Replace 才换（方案第 15 条）。
// 不管什么：裁 / 传 / 下 / 封声（UpscalePipeline）、换源（VideoEditProject+Upscale）、界面。

@MainActor
final class UpscaleJob: ObservableObject, Identifiable {
    enum State: Equatable {
        /// 跑着：阶段、这一阶段从什么时候起、这一档通常要多久（FalJobProgress）。
        case running(FalJobProgress)
        case done
        case failed(String)
        case cancelled
        /// AI 起的：用户在提示条上没点头（没花钱）。
        case declined
    }

    /// 花钱怎么把关：面板上的估价就是用户的确认（方案第 10 条，直接记账）；AI 起的（upscale_clip）按每日上限 —— 额度内直接做、
    /// 超了在提示条上问（FalJobGate，和 generate_media 同一处）。
    enum Approval {
        case panel
        case dailyLimit(project: VideoEditProject)
    }

    let id = UUID()
    let request: UpscaleRequest
    /// 做的是哪一段（状态行上「Upscaling <名字> with …」）。
    let title: String
    /// 范围被盖住、做完要换的段。
    let clipIDs: [UUID]
    /// 这段所在的工程（做完换源时核对还是不是它）。
    let projectGeneration: Int
    let approval: Approval

    @Published private(set) var state: State
    @Published private(set) var outcome: UpscaleOutcome?
    /// 账单明细查到的实际扣费；nil = 还没查到 / 查不到。
    @Published private(set) var actualCost: Double?
    /// macOS 正在问要不要让 SrtFlow 用钥匙串里的 Key（界面提醒用户点「始终允许」）。
    @Published private(set) var keyPrompt = false
    /// AI 起的任务在等用户动手（提示条上点头、钥匙串授权框）时给 AI 看的话（任务的 `waiting_for_user`）；没在等就是 nil。
    @Published private(set) var waiting: String?
    /// 做完（拿到文件）时叫一声：UpscaleActivity 用它弹对比窗口，upscale_clip 用它直接换源。
    var onFinished: ((UpscaleJob) -> Void)?
    /// 怎么结束都叫一声（done 在 onFinished 之后；failed / cancelled / declined）：upscale_clip 用它把结局记给 AI 的任务。
    var onEnded: ((UpscaleJob) -> Void)?

    private var task: Task<Void, Never>?
    private var reserved: (amount: Double, day: Date)?
    private var resultReceived = false

    init(request: UpscaleRequest, clipIDs: [UUID], projectGeneration: Int, title: String, approval: Approval = .panel) {
        self.request = request
        self.clipIDs = clipIDs
        self.projectGeneration = projectGeneration
        self.title = title
        self.approval = approval
        state = .running(FalJobProgress(phase: .preparing, typicalSeconds: request.tier.typicalSeconds))
    }

    static var workFolder: URL { FileManager.default.temporaryDirectory.appendingPathComponent("SrtFlowUpscale", isDirectory: true) }

    func start() {
        guard task == nil else { return }
        task = Task { @MainActor in await self.execute() }
    }

    func cancel() {
        task?.cancel()
        // AI 起的：挂在提示条上的问题一起收回。
        if case .dailyLimit = approval { AISession.shared.withdrawQuestions(owner: id.uuidString) }
    }

    private func execute() async {
        let store = FalSettingsStore.shared
        // 1. 账。
        switch approval {
        case .panel:
            // 面板上已经确认过，直接记上估算。
            store.recordSpend(request.estimate)
            reserved = (request.estimate, Date())
        case .dailyLimit(let project):
            // AI 起的：按每日上限把关，超了在提示条上问（FalJobGate）。
            let summary = "\(request.tier.title) · \(request.tier.detail) · \(Int(request.range.duration.rounded())) s · \(request.target.label)"
            switch await FalJobGate.reserve(
                estimate: request.estimate, summary: summary, owner: id.uuidString, project: project, waiting: { [weak self] in self?.waiting = $0 }
            ) {
            case .reserved(let reservation):
                reserved = (reservation.amount, reservation.day)
            case .declined:
                state = .declined
                onEnded?(self)
                return
            }
            guard !Task.isCancelled else {
                refund(store)
                state = .cancelled
                onEnded?(self)
                return
            }
        }

        // 2. Key。
        let aiDriven: Bool
        if case .dailyLimit = approval { aiDriven = true } else { aiDriven = false }
        let hinted = FalPromptFlag()
        let keyResult = await FalKeyCache.shared.key(willAsk: { [weak self] in
            self?.keyPrompt = true
            guard aiDriven else { return }
            hinted.value = true
            self?.waiting = FalJobGate.keyPromptWaiting
            FalJobGate.showKeyPromptHint()
        })
        keyPrompt = false
        waiting = nil
        if hinted.value { FalJobGate.clearKeyPromptHint() }
        guard case .key(let key) = keyResult else {
            refund(store)
            state = .failed(keyResult == .missing ? FalError.noKey.message : "SrtFlow could not read the fal.ai key from the macOS keychain.")
            onEnded?(self)
            return
        }

        // 3. 流水线。
        let client = FalClient(base: FalClient.configuredBase()) { key }
        let ffmpeg = MediaToolchain.shared.runtime?.url
        do {
            let result = try await UpscalePipeline.run(request, client: client, ffmpeg: ffmpeg, workFolder: Self.workFolder) { [weak self] phase in
                Task { @MainActor in
                    guard let self, case .running(let progress) = self.state else { return }
                    self.state = .running(progress.advanced(to: phase))
                    if case .downloading = phase { self.resultReceived = true }
                }
            }
            resultReceived = true
            outcome = result
            state = .done
            onFinished?(self)
            onEnded?(self)
            await lookUpCost(client: client, requestID: result.requestID, since: Date().addingTimeInterval(-result.elapsed - 600))
        } catch is CancellationError {
            refund(store)
            state = .cancelled
            onEnded?(self)
        } catch let error as FalError {
            refund(store)
            state = .failed(error.message)
            onEnded?(self)
        } catch let error as UpscalePipelineError {
            refund(store)
            state = .failed(error.message)
            onEnded?(self)
        } catch {
            refund(store)
            state = .failed(error.localizedDescription)
            onEnded?(self)
        }
    }

    /// 没做出来才退：fal 只对做出来的收钱。
    private func refund(_ store: FalSettingsStore) {
        guard !resultReceived, let reserved else { return }
        store.refundSpend(reserved.amount, on: reserved.day)
        self.reserved = nil
    }

    /// 账单明细一般几分钟内出现：每 30 秒问一次、最多六次。查到了把账本里的估算换成实收。
    private func lookUpCost(client: FalClient, requestID: String, since: Date) async {
        for attempt in 0..<6 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 30_000_000_000) }
            guard let events = try? await client.billingEvents(requestIDs: [requestID], since: since) else { return }
            if let cost = FalBilling.cost(of: requestID, in: events) {
                actualCost = cost
                outcome?.record.costUSD = cost
                if let reserved {
                    FalSettingsStore.shared.refundSpend(reserved.amount, on: reserved.day)
                    FalSettingsStore.shared.recordSpend(cost)
                    self.reserved = nil
                }
                return
            }
        }
    }
}

/// 面板要为哪一段打开（右键菜单、检查器都走这里）。
struct UpscalePanelTarget: Identifiable, Equatable {
    let id: UUID
}

/// 对比窗口看什么：做完还没处理的任务（点替换才换源），或已经换过源的一段（原片 vs 现在用的）。
enum UpscaleCompareTarget: Identifiable, Equatable {
    case job(UpscaleJob)
    case clip(UUID)

    var id: String {
        switch self {
        case .job(let job): return "job-" + job.id.uuidString
        case .clip(let id): return "clip-" + id.uuidString
        }
    }

    static func == (lhs: UpscaleCompareTarget, rhs: UpscaleCompareTarget) -> Bool { lhs.id == rhs.id }
}

/// 正在做 / 做完还没处理的 upscale 任务，以及界面上要摆出来的面板和对比窗口（界面从这里读；切工程时清掉）。
@MainActor
final class UpscaleActivity: ObservableObject {
    static let shared = UpscaleActivity()
    @Published private(set) var jobs: [UpscaleJob] = []
    @Published var panel: UpscalePanelTarget?
    @Published var compare: UpscaleCompareTarget?

    /// `opensCompare`：面板起的做完先弹对比窗口（方案第 15 条）；AI 起的（upscale_clip）自己接 `onFinished` 直接换源，不弹。
    func add(_ job: UpscaleJob, opensCompare: Bool = true) {
        jobs.append(job)
        if opensCompare {
            job.onFinished = { [weak self] finished in
                // 已经在看别的就不抢。
                guard let self, self.jobs.contains(where: { $0.id == finished.id }), self.compare == nil else { return }
                self.compare = .job(finished)
            }
        }
        job.start()
    }

    func remove(_ job: UpscaleJob) {
        job.cancel()
        jobs.removeAll { $0.id == job.id }
        if compare == .job(job) { compare = nil }
    }

    /// 这个原片有没有在做 / 做完还没处理的任务。
    func job(forOriginal url: URL) -> UpscaleJob? {
        jobs.first { $0.request.originalURL == url }
    }

    func present(panelFor clipID: UUID) { panel = UpscalePanelTarget(id: clipID) }

    func cancelAll() {
        for job in jobs { job.cancel() }
        jobs.removeAll()
        panel = nil
        compare = nil
    }
}
