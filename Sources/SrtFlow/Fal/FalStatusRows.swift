import SwiftUI

// MARK: - 编辑器顶上的状态行：正在送 fal 的活（upscale、generate_media）做到哪一步
//
// 管什么：挂在「AI 正在剪辑」那条横幅底下（AIActivityBanner），每个在跑 / 做完还没处理的 fal 任务一行：做什么、
// 四个阶段的小标（上传 · 排队 · 处理 · 下载，当前的那个带百分比 / 已用时间和「通常约几分钟」）、估价、停止；
// upscale 做完那一行给 Compare… / Dismiss（mockup「Status row while upscaling」）。还有检查器那一节用的
// 阶段文字（`FalPhaseText`）和每秒走一下的钟（`FalPhaseClock`）。
// 只订阅两个小对象（UpscaleActivity、FalGenerationActivity），不读工程；没有任务时什么都不画、也不醒
// （docs/architecture/preview-perf-ratchet.md：性能场景里没有 fal 任务，这几个视图的计数是零）。
// 不管什么：任务怎么跑、阶段怎么量（UpscaleJob / FalGenerationRun）。

struct FalStatusRows: View, Equatable {
    @ObservedObject private var upscale = UpscaleActivity.shared
    @ObservedObject private var generation = FalGenerationActivity.shared

    /// 横幅每重算一次都会重新造它：没有输入，永远相等 —— 只有两个活动对象发了变化才重算（挂在横幅底下不动性能基线）。
    static func == (lhs: FalStatusRows, rhs: FalStatusRows) -> Bool { true }

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        ForEach(upscale.jobs) { job in
            UpscaleStatusRow(job: job, activity: upscale)
        }
        ForEach(generation.runs) { run in
            GenerationStatusRow(run: run)
        }
    }
}

/// 一个 upscale 任务的那一行（只订阅这一个任务）。
struct UpscaleStatusRow: View {
    @ObservedObject var job: UpscaleJob
    let activity: UpscaleActivity

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        let tier = job.request.tier
        switch job.state {
        case .running(let progress):
            FalStatusBar(icon: "arrow.up.left.and.arrow.down.right", message: String(format: L10n("Upscaling %@ with %@"), job.title, "\(tier.title) · \(tier.detail)")) {
                FalPhasePills(progress: progress, showsUpload: true)
                Text(String(format: L10n("est. %@"), FalMoney.text(job.request.estimate)))
                    .font(.caption).foregroundStyle(.secondary)
                Button("Stop") { activity.remove(job) }
            }
        case .done:
            let size = job.outcome?.info.resolutionLabel ?? ""
            let cost = job.actualCost.map { String(format: L10n("%@ charged"), FalMoney.text($0)) }
                ?? String(format: L10n("est. %@"), FalMoney.text(job.request.estimate))
            FalStatusBar(icon: "checkmark.circle", message: String(format: L10n("%@ upscaled to %@ · %@"), job.title, size, cost)) {
                Button("Compare…") { activity.compare = .job(job) }
                Button("Dismiss") { activity.remove(job) }
            }
        case .failed(let message):
            FalStatusBar(icon: "exclamationmark.triangle", message: String(format: L10n("Upscale failed: %@"), message)) {
                Button("Dismiss") { activity.remove(job) }
            }
        case .cancelled, .declined:
            FalStatusBar(icon: "stop.circle", message: L10n("Upscale cancelled.")) {
                Button("Dismiss") { activity.remove(job) }
            }
        }
    }
}

/// 一个 generate_media 任务的那一行（只订阅这一个任务；做完就从活动里拿掉、这一行消失）。
struct GenerationStatusRow: View {
    @ObservedObject var run: FalGenerationRun

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        FalStatusBar(icon: "sparkles", message: String(format: L10n("Generating %@ with %@"), run.kindLabel, run.modelTitle)) {
            if let progress = run.progress {
                FalPhasePills(progress: progress, showsUpload: false)
            }
            if let estimate = run.estimate {
                Text(String(format: L10n("est. %@"), FalMoney.text(estimate)))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Stop") { run.cancel() }
        }
    }
}

/// 一行的壳：图标 · 一句话 · 右边的小件（和 AIActivityBanner 的 bar 同一个样子）。
struct FalStatusBar<Trailing: View>: View {
    let icon: String
    let message: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(.tint)
                Text(verbatim: message)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                trailing()
                    .controlSize(.small)
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.tint.opacity(0.12))
            Divider()
        }
    }
}

/// 四个阶段的小标：过了的打勾、当前的带数字、还没到的灰着。每秒走一下（「处理 1:12」）。
struct FalPhasePills: View {
    let progress: FalJobProgress
    /// generate_media 没有上传这一步（图是内嵌的）。
    let showsUpload: Bool

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 4) {
                ForEach(steps, id: \.order) { step in
                    pill(step, now: context.date)
                }
            }
        }
    }

    /// 画哪几个：上传（要的话）· 排队 · 处理 · 下载；准备 / 收尾只在正是那一步时露面。
    private var steps: [FalJobPhase] {
        var list: [FalJobPhase] = []
        if progress.phase.order == FalJobPhase.preparing.order { list.append(.preparing) }
        if showsUpload { list.append(.uploading(fraction: nil)) }
        list += [.queued(position: nil), .processing, .downloading(fraction: nil)]
        if progress.phase.order == FalJobPhase.finishing.order { list.append(.finishing) }
        return list
    }

    private func pill(_ step: FalJobPhase, now: Date) -> some View {
        let current = progress.phase.order
        let state: FalPhaseText.PillState = step.order < current ? .done : (step.order == current ? .current : .upcoming)
        let text = FalPhaseText.pill(progress, step: step, state: state, now: now)
        return HStack(spacing: 3) {
            if state == .done {
                Image(systemName: "checkmark").font(.system(size: 8, weight: .bold))
            }
            Text(verbatim: text)
        }
        // 小标不折行、不被挤扁（2026-10-02 冒烟：窗口窄时「Downloading」折成两行）；地方不够让左边那句话去截。
        .lineLimit(1)
        .fixedSize()
        .font(.caption)
        .foregroundStyle(state == .upcoming ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(state == .current ? AnyShapeStyle(.tint.opacity(0.3)) : AnyShapeStyle(.quaternary)))
    }
}

/// 检查器那一节用：一句阶段文字，每秒走一下。
struct FalPhaseClock: View {
    let progress: FalJobProgress
    let prefix: String

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(verbatim: prefix + FalPhaseText.inspector(progress, now: context.date))
        }
    }
}

/// 阶段怎么写成字（本地化）：检查器里小写的一句、状态行上的小标。
enum FalPhaseText {
    enum PillState: Equatable { case done, current, upcoming }

    /// 检查器：「uploading 35%」「in queue (3)」「processing 1:12 · usually about 2 min」「downloading 80%」。
    static func inspector(_ progress: FalJobProgress, now: Date) -> String {
        switch progress.phase {
        case .preparing: return L10n("preparing")
        case .uploading(let fraction): return L10n("uploading") + percentSuffix(fraction)
        case .queued(let position): return position.map { String(format: L10n("in queue (%d)"), $0) } ?? L10n("in queue")
        case .processing: return L10n("processing") + " " + FalJobProgress.clock(progress.phaseSeconds(now: now)) + usuallySuffix(progress)
        case .downloading(let fraction): return L10n("downloading") + percentSuffix(fraction)
        case .finishing: return L10n("finishing")
        }
    }

    /// 状态行上的小标：当前的那个带百分比 / 已用时间，别的只有名字。
    static func pill(_ progress: FalJobProgress, step: FalJobPhase, state: PillState, now: Date) -> String {
        guard state == .current else { return title(step) }
        switch progress.phase {
        case .preparing: return L10n("Preparing")
        case .uploading(let fraction): return fraction.map { String(format: L10n("Uploading %d%%"), Int(($0 * 100).rounded())) } ?? L10n("Uploading")
        case .queued(let position): return position.map { String(format: L10n("In queue (%d)"), $0) } ?? L10n("In queue")
        case .processing:
            return String(format: L10n("Processing %@"), FalJobProgress.clock(progress.phaseSeconds(now: now))) + usuallySuffix(progress)
        case .downloading(let fraction): return fraction.map { String(format: L10n("Downloading %d%%"), Int(($0 * 100).rounded())) } ?? L10n("Downloading")
        case .finishing: return L10n("Finishing")
        }
    }

    private static func title(_ step: FalJobPhase) -> String {
        switch step {
        case .preparing: return L10n("Preparing")
        case .uploading: return L10n("Uploading")
        case .queued: return L10n("In queue")
        case .processing: return L10n("Processing")
        case .downloading: return L10n("Downloading")
        case .finishing: return L10n("Finishing")
        }
    }

    private static func percentSuffix(_ fraction: Double?) -> String {
        fraction.map { " \(Int(($0 * 100).rounded()))%" } ?? ""
    }

    /// 「 · usually about 2 min」：知道这一档通常要多久才加。
    private static func usuallySuffix(_ progress: FalJobProgress) -> String {
        progress.typicalSeconds.map { " · " + String(format: L10n("usually about %d min"), FalJobProgress.minutes($0)) } ?? ""
    }
}
