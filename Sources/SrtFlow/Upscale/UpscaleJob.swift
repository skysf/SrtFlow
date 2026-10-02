import Foundation

// MARK: - 用户点了「开始」之后的那个任务：记账 → 取 Key → 跑流水线 → 对账实际扣费
//
// 管什么：面板上的估价已经是用户的确认（方案第 10 条：记进 fal 的账本、超限只标红不拦），所以这里不再问；取 Key（钥匙串，
// 新版本第一次读会弹授权框，`keyPrompt` 让界面说一句）；跑 `UpscalePipeline`，阶段发给界面；做完几分钟内去账单明细里
// 把实际扣费查回来（要 ADMIN 权限的 Key，查不到就只有估价）。没做出来的钱退回（照 FalGenerationRun 的规矩：拿到结果就不退）。
// 做完**不替换**：对比窗口里用户点了 Replace 才换（方案第 15 条）。
// 不管什么：裁 / 传 / 下 / 封声（UpscalePipeline）、换源（VideoEditProject+Upscale）、界面。

@MainActor
final class UpscaleJob: ObservableObject, Identifiable {
    enum State: Equatable {
        case running(UpscalePhase)
        case done
        case failed(String)
        case cancelled
    }

    let id = UUID()
    let request: UpscaleRequest
    /// 范围被盖住、做完要换的段。
    let clipIDs: [UUID]
    /// 这段所在的工程（做完换源时核对还是不是它）。
    let projectGeneration: Int

    @Published private(set) var state: State = .running(.preparing)
    @Published private(set) var outcome: UpscaleOutcome?
    /// 账单明细查到的实际扣费；nil = 还没查到 / 查不到。
    @Published private(set) var actualCost: Double?
    /// macOS 正在问要不要让 SrtFlow 用钥匙串里的 Key（界面提醒用户点「始终允许」）。
    @Published private(set) var keyPrompt = false

    private var task: Task<Void, Never>?
    private var reserved: (amount: Double, day: Date)?
    private var resultReceived = false

    init(request: UpscaleRequest, clipIDs: [UUID], projectGeneration: Int) {
        self.request = request
        self.clipIDs = clipIDs
        self.projectGeneration = projectGeneration
    }

    static var workFolder: URL { FileManager.default.temporaryDirectory.appendingPathComponent("SrtFlowUpscale", isDirectory: true) }

    func start() {
        guard task == nil else { return }
        task = Task { @MainActor in await self.execute() }
    }

    func cancel() {
        task?.cancel()
    }

    private func execute() async {
        let store = FalSettingsStore.shared
        // 1. 账：面板上已经确认过，直接记上估算。
        store.recordSpend(request.estimate)
        reserved = (request.estimate, Date())

        // 2. Key。
        let keyResult = await FalKeyCache.shared.key(willAsk: { [weak self] in self?.keyPrompt = true })
        keyPrompt = false
        guard case .key(let key) = keyResult else {
            refund(store)
            state = .failed(keyResult == .missing ? FalError.noKey.message : "SrtFlow could not read the fal.ai key from the macOS keychain.")
            return
        }

        // 3. 流水线。
        let client = FalClient(base: FalClient.configuredBase()) { key }
        let ffmpeg = MediaToolchain.shared.runtime?.url
        do {
            let result = try await UpscalePipeline.run(request, client: client, ffmpeg: ffmpeg, workFolder: Self.workFolder) { [weak self] phase in
                Task { @MainActor in
                    guard let self, case .running = self.state else { return }
                    self.state = .running(phase)
                    if phase == .downloading { self.resultReceived = true }
                }
            }
            resultReceived = true
            outcome = result
            state = .done
            await lookUpCost(client: client, requestID: result.requestID, since: Date().addingTimeInterval(-result.elapsed - 600))
        } catch is CancellationError {
            refund(store)
            state = .cancelled
        } catch let error as FalError {
            refund(store)
            state = .failed(error.message)
        } catch let error as UpscalePipelineError {
            refund(store)
            state = .failed(error.message)
        } catch {
            refund(store)
            state = .failed(error.localizedDescription)
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

/// 正在做 / 做完还没处理的 upscale 任务（界面从这里读；切工程时清掉）。
@MainActor
final class UpscaleActivity: ObservableObject {
    static let shared = UpscaleActivity()
    @Published private(set) var jobs: [UpscaleJob] = []

    func add(_ job: UpscaleJob) {
        jobs.append(job)
        job.start()
    }

    func remove(_ job: UpscaleJob) {
        job.cancel()
        jobs.removeAll { $0.id == job.id }
    }

    func cancelAll() {
        for job in jobs { job.cancel() }
        jobs.removeAll()
    }
}
