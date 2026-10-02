import Foundation
import SrtFlowMCPKit

// MARK: - fal 任务的阶段与进度账（纯值）
//
// 管什么：一次送 fal 的活（upscale、generate_media）走到了哪一步：裁 / 上传（带字节比例）/ 排队（带位置）/ 处理 / 下载（带字节比例）/
// 收尾；这一阶段从什么时候起、这一档通常要多久；给 `get_job` 的那几个字段（`phase`、`queue_position`、`transfer_percent`、
// `phase_seconds`、`typical_seconds`）和界面上「1:12」「约 2 分钟」怎么算。fal 处理中**没有百分比**（队列接口只给排队位置和
// 「处理中」），所以能给的就是阶段 + 排队位置 + 已用时间 + 典型时长，不画假进度条（docs/architecture/fal-generation.md 第十三节）。
// 不管什么：阶段怎么量出来（FalClient / UpscalePipeline / FalGenerationRun）、怎么画（FalStatusRows、UpscaleJobStatusView）。

enum FalJobPhase: Equatable, Sendable {
    /// 裁出那一段（upscale）/ 把关花钱、取 Key（generate_media）。
    case preparing
    /// 上传到 fal 的存储；`fraction` 是发出去的字节比例（0…1），还不知道就是 nil。
    case uploading(fraction: Double?)
    case queued(position: Int?)
    case processing
    /// 下载成品；`fraction` 是收到的字节比例，服务器没说总长就是 nil。
    case downloading(fraction: Double?)
    /// 封回原声、探测、落盘（upscale）/ 存文件（generate_media）。
    case finishing

    /// 六步的名字（给 AI 和日志看、`get_job` 的 `phase`），声明的顺序就是先后。
    enum Step: String, CaseIterable, Sendable {
        case preparing, uploading, queued, processing, downloading, finishing
    }

    var step: Step {
        switch self {
        case .preparing: return .preparing
        case .uploading: return .uploading
        case .queued: return .queued
        case .processing: return .processing
        case .downloading: return .downloading
        case .finishing: return .finishing
        }
    }

    var name: String { step.rawValue }

    /// 上传 / 下载的字节比例（0…1）；别的阶段、或还不知道，都是 nil。
    var fraction: Double? {
        switch self {
        case .uploading(let fraction), .downloading(let fraction): return fraction
        default: return nil
        }
    }

    var queuePosition: Int? {
        if case .queued(let position) = self { return position }
        return nil
    }

    /// 同一阶段换一个比例 / 换一个排队位置不算换阶段（界面从「上传」变成「排队」才重记开始时刻）。
    func sameStep(as other: FalJobPhase) -> Bool { step == other.step }

    /// 阶段的先后（状态行上画「上传 · 排队 · 处理 · 下载」要知道谁在前、谁已经过了）。
    var order: Int { Step.allCases.firstIndex(of: step) ?? 0 }

    /// 字节比例按 1% 一格（每收一块都报的话界面每秒要醒几十次）。
    static func quantized(_ fraction: Double) -> Double {
        (min(1, max(0, fraction)) * 100).rounded(.down) / 100
    }
}

/// 一个跑着的 fal 任务此刻的进度账：阶段、这一阶段从什么时候起、处理通常要多久。
struct FalJobProgress: Equatable, Sendable {
    var phase: FalJobPhase
    /// 这一阶段开始的时刻（换一个阶段才重记；上传从 0% 到 100% 都算同一阶段）。
    var phaseStarted: Date
    /// 这一档 / 这一种事从提交到做完通常要几秒（含排队；2026-10-02 实测），不知道就是 nil。
    var typicalSeconds: Double?

    init(phase: FalJobPhase, phaseStarted: Date = Date(), typicalSeconds: Double? = nil) {
        self.phase = phase
        self.phaseStarted = phaseStarted
        self.typicalSeconds = typicalSeconds
    }

    /// 换到 `next`：同一阶段只换比例（开始时刻不动），换了阶段才重记开始时刻。
    func advanced(to next: FalJobPhase, now: Date = Date()) -> FalJobProgress {
        var copy = self
        copy.phase = next
        if !phase.sameStep(as: next) { copy.phaseStarted = now }
        return copy
    }

    func phaseSeconds(now: Date = Date()) -> Double { max(0, now.timeIntervalSince(phaseStarted)) }

    /// `get_job` 跑着时的那几个字段。
    func json(now: Date = Date()) -> [String: JSONValue] {
        var object: [String: JSONValue] = [
            "phase": .string(phase.name),
            "phase_seconds": .number(phaseSeconds(now: now).rounded())
        ]
        if let position = phase.queuePosition { object["queue_position"] = .number(Double(position)) }
        if let fraction = phase.fraction { object["transfer_percent"] = .number((fraction * 100).rounded()) }
        if let typicalSeconds { object["typical_seconds"] = .number(typicalSeconds.rounded()) }
        return object
    }

    /// 「1:12」：这一阶段已经过了多久。
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// 「约 2 分钟」里的那个数：四舍五入到整分钟，不满一分钟算一分钟。
    static func minutes(_ seconds: Double) -> Int { max(1, Int((seconds / 60).rounded())) }
}

/// 上一次报过的阶段（带锁：fal 的回调在别的线程上）。同一阶段同一比例只报一次。
final class FalPhaseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var last: FalJobPhase?

    /// 换成 `next`；和上一次一样就返回 false。
    func swap(_ next: FalJobPhase) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if last == next { return false }
        last = next
        return true
    }
}
