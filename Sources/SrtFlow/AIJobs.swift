import Foundation
import SrtFlowMCPKit

// MARK: - AI 起的长任务：导出、生成字幕、翻译
//
// 管什么：任务号、进度、结局。工具起了任务就立刻回任务号（客户端对一次调用大多只等一分钟），
// AI 用 get_job 等结果。结局在任务结束的**那一刻**记下（由各工具挂的完成回调写），
// 之后用户再手动导出一次、把导出器的状态换掉，也不会串到这个任务上。
// 不管什么：任务本身怎么跑（`VideoEditExporter`、`TranscriptionTask`、翻译服务）。

@MainActor
final class AIJobs {
    static let shared = AIJobs()

    enum Kind: String {
        case export, subtitles, translation
    }

    enum Status: String {
        case running, done, failed, cancelled
    }

    final class Job {
        let id: String
        let kind: Kind
        let startedAt = Date()
        /// 跑着的时候的进度（0…1），读不到就是 nil。
        let progress: @MainActor () -> Double?
        let cancelAction: @MainActor () -> Void
        fileprivate(set) var status: Status = .running
        fileprivate(set) var message: String?
        fileprivate(set) var detail: JSONValue?
        fileprivate(set) var finishedAt: Date?

        init(id: String, kind: Kind, progress: @escaping @MainActor () -> Double?, cancel: @escaping @MainActor () -> Void) {
            self.id = id
            self.kind = kind
            self.progress = progress
            self.cancelAction = cancel
        }
    }

    private var jobs: [String: Job] = [:]
    private var counter = 0

    private init() {}

    func start(
        _ kind: Kind, progress: @escaping @MainActor () -> Double?, cancel: @escaping @MainActor () -> Void
    ) -> Job {
        counter += 1
        let job = Job(id: "\(kind.rawValue)-\(counter)", kind: kind, progress: progress, cancel: cancel)
        jobs[job.id] = job
        return job
    }

    /// 任务结束时由起它的工具调用一次。只认第一次。
    func finish(_ job: Job, _ status: Status, message: String? = nil, detail: JSONValue? = nil) {
        guard job.status == .running else { return }
        job.status = status
        job.message = message
        job.detail = detail
        job.finishedAt = Date()
    }

    var running: [Job] {
        jobs.values.filter { $0.status == .running }.sorted { $0.startedAt < $1.startedAt }
    }

    func job(_ id: String) -> Job? { jobs[id] }

    /// 等到任务结束或者超时（最多 30 秒，给客户端的一分钟留足余量）。
    func wait(for job: Job, seconds: Double) async {
        let deadline = Date().addingTimeInterval(min(max(seconds, 0), 30))
        while job.status == .running, Date() < deadline {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    func cancel(_ job: Job) {
        guard job.status == .running else { return }
        job.cancelAction()
    }

    /// 用户在横幅上按了停止。
    func cancelAll() {
        for job in running { job.cancelAction() }
    }

    func json(_ job: Job) -> JSONValue {
        var object: [String: JSONValue] = [
            "job_id": .string(job.id),
            "kind": .string(job.kind.rawValue),
            "status": .string(job.status.rawValue),
            "elapsed_seconds": .number(((job.finishedAt ?? Date()).timeIntervalSince(job.startedAt)).rounded())
        ]
        if job.status == .running, let progress = job.progress() {
            object["progress"] = .number((progress * 100).rounded() / 100)
        }
        if let message = job.message { object["message"] = .string(message) }
        if let detail = job.detail, case .object(let extra) = detail {
            object.merge(extra) { current, _ in current }
        }
        return .object(object)
    }
}
