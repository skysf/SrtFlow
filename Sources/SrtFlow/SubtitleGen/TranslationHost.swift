import SwiftUI
import Translation

// 常驻 Translation Host（docs/plans/2026-08-06-native-subtitle-generation.md 3.4）。
//
// TranslationSession 只能由 SwiftUI `.translationTask` 提供，且**不得离开
// 那个闭包**（不能存进队列/单例/模型）。所以这里拆成两半：
// - TranslationJobCoordinator（@MainActor 单例）只保存 job / config / result；
// - TranslationHostView 是挂在主窗口上的零尺寸常驻视图，持有 translationTask，
//   闭包拿到 session 后回调 coordinator 执行当前 job。
// 模型下载的系统交互也发生在这条链路上（prepareTranslation）。
// 注意：Translation 栈依赖主队列被服务（Phase 0 实测），App 内天然满足。

@available(macOS 15.0, *)
@MainActor
final class TranslationJobCoordinator: ObservableObject {
    static let shared = TranslationJobCoordinator()

    struct CueRequest: Sendable {
        var cueID: UUID
        var text: String
    }

    enum Phase: Equatable {
        case idle
        case running(completed: Int, total: Int)
        case failed(String)
    }

    struct HostError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// 一次待执行任务：jobID 和触发它的 configuration **绑在一起**发布，
    /// HostView 在同一次 body 求值里把两者一起捕获进 action 闭包 ——
    /// 迟到的旧 action 带着旧 jobID 进门，对不上号当场退场，
    /// 绝不认领新任务的 continuation（评审 P1：身份必须随 action 传递）。
    struct PendingJob {
        let id: UUID
        let configuration: TranslationSession.Configuration
    }

    @Published private(set) var phase: Phase = .idle
    /// translationTask 的触发器。每个 job 一份；job 结束置回 nil。
    @Published private(set) var pendingJob: PendingJob?

    private var pending: [CueRequest] = []
    private var continuation: CheckedContinuation<[UUID: String], Error>?
    private var cancelRequested = false
    /// 当前任务的身份：finish/phase 只认对得上号的（旧 action 迟到收尾
    /// 不许误伤新任务）。
    private var currentJobID: UUID?
    /// SwiftUI 是否已经把 session 交给 run(session:)。**没起跑就取消时，
    /// 没有任何 action 会替我们收尾 —— 必须当场了结自己的 continuation**，
    /// 否则调用方永远挂着、isBusy 永远为真（评审 P1）。
    private var actionStarted = false
    /// 批间检查取消用的批大小（产品参数，实测后调）。
    private let batchSize = 32

    var isBusy: Bool { continuation != nil }

    /// 提交一批 cue 文本，等待逐条译文（键 = cueID）。串行：忙时直接拒绝。
    func translate(
        _ requests: [CueRequest],
        source: Locale.Language?,
        target: Locale.Language
    ) async throws -> [UUID: String] {
        guard !isBusy else {
            throw HostError(message: L10n("Another translation is still running."))
        }
        guard !requests.isEmpty else { return [:] }
        cancelRequested = false
        actionStarted = false
        let jobID = UUID()
        currentJobID = jobID
        pending = requests
        phase = .running(completed: 0, total: requests.count)
        return try await withCheckedThrowingContinuation { cont in
            continuation = cont
            pendingJob = PendingJob(
                id: jobID,
                configuration: TranslationSession.Configuration(source: source, target: target)
            )
        }
    }

    func cancel() {
        guard isBusy else { return }
        cancelRequested = true
        // 清掉 pendingJob：translationTask 按 .task(id:) 语义**取消正在跑的
        // action task**。run 里的结构化 cancellation handler 会就地调
        // session.cancel()（macOS 26），session 全程不离开 action 的生命周期；
        // 15–25 靠 execute 里每个 await 前后的检查兜住。
        pendingJob = nil
        // 排队中取消（action 还没拿到 session）：当场收尾。全程 MainActor
        // 串行，晚到的 run 会因 jobID 对不上号直接退场。
        if !actionStarted {
            finish(.failure(CancellationError()), for: currentJobID)
        }
    }

    /// 只由 TranslationHostView 的 translationTask 闭包调用；session 不出本函数
    /// （连取消通道也不出：cancellation handler 在本函数的结构化作用域内捕获）。
    /// jobID 由 HostView 从触发本次 action 的 PendingJob 里带进来 —— 进门先
    /// 验明正身，旧 configuration 的迟到 action 不许碰新任务。
    /// 取消面（评审 P1）：单批任务在 `translations(from:)` 执行期间点 Stop，
    /// 没有「下一批」可查 —— 所以**每个 await 之后**和**最终 success 之前**
    /// 都必须复查，绝不把取消后的结果报成成功。
    func run(session: TranslationSession, jobID: UUID) async {
        guard jobID == currentJobID, continuation != nil, !actionStarted else { return }
        actionStarted = true
        let requests = pending
        do {
            let results = try await withTaskCancellationHandler {
                try await self.execute(requests: requests, session: session, jobID: jobID)
            } onCancel: {
                if #available(macOS 26.0, *) { session.cancel() }
            }
            finish(.success(results), for: jobID)
        } catch is CancellationError {
            finish(.failure(CancellationError()), for: jobID)
        } catch {
            // 取消后 session 可能以自家错误浮出，统一按取消收尾。
            if cancelRequested || Task.isCancelled {
                finish(.failure(CancellationError()), for: jobID)
            } else {
                finish(.failure(error), for: jobID)
            }
        }
    }

    private func execute(
        requests: [CueRequest], session: TranslationSession, jobID: UUID
    ) async throws -> [UUID: String] {
        // 任务被顶替（新 translate 已开跑）也算取消：旧 action 立即罢手，
        // 不许再碰共享 phase。
        func checkpoint() throws {
            guard jobID == currentJobID, !cancelRequested, !Task.isCancelled else {
                throw CancellationError()
            }
        }
        try checkpoint()
        // 需要下载模型时由系统在这里弹交互（形态随系统版本）。
        try await session.prepareTranslation()
        try checkpoint()
        var results: [UUID: String] = [:]
        var completed = 0
        for chunk in stride(from: 0, to: requests.count, by: batchSize).map({
            Array(requests[$0..<min($0 + batchSize, requests.count)])
        }) {
            try checkpoint()
            let batch = chunk.map {
                TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.cueID.uuidString)
            }
            let responses = try await session.translations(from: batch)
            try checkpoint()
            for response in responses {
                if let id = response.clientIdentifier.flatMap(UUID.init(uuidString:)) {
                    results[id] = response.targetText
                }
            }
            completed += chunk.count
            phase = .running(completed: completed, total: requests.count)
        }
        try checkpoint()
        return results
    }

    private func finish(_ result: Result<[UUID: String], Error>, for jobID: UUID?) {
        guard let cont = continuation, jobID == currentJobID else { return }
        continuation = nil
        pending = []
        currentJobID = nil
        actionStarted = false
        pendingJob = nil
        switch result {
        case .success(let translations):
            phase = .idle
            cont.resume(returning: translations)
        case .failure(let error):
            phase = error is CancellationError
                ? .idle : .failed(TranslationErrorText.describe(error))
            cont.resume(throwing: error)
        }
    }
}

@available(macOS 15.0, *)
struct TranslationHostView: View {
    @ObservedObject private var coordinator = TranslationJobCoordinator.shared

    var body: some View {
        // 零尺寸但常驻视图树：translationTask 的宿主。
        // job 在**同一次 body 求值**里被捕获进 action：这次 action 拿到的
        // session 就绑定这个 jobID，configuration 换代后旧 action 迟到也
        // 只能带着旧 ID 进门（Apple 语义：session 与触发它的 configuration
        // 绑定，换代即失效）。
        let job = coordinator.pendingJob
        Color.clear
            .frame(width: 0, height: 0)
            .translationTask(job?.configuration) { session in
                guard let job else { return }
                await coordinator.run(session: session, jobID: job.id)
            }
    }
}

/// 把 TranslationError 翻成能行动的文案（阶段化错误，计划 12.6）。
@available(macOS 15.0, *)
enum TranslationErrorText {
    static func describe(_ error: Error) -> String {
        let text = error.localizedDescription
        if text.isEmpty {
            return L10n("Translation failed for an unknown reason.")
        }
        return text
    }
}
