import SwiftUI

// MARK: - 检查器里正在做 / 做完还没处理的 upscale 任务
//
// 管什么：`UpscaleJobStatusView` 只订阅那一个任务，阶段每变一次只有它重算（检查器本体不动）。
// 检查器里「Upscale」那一节本身在 VideoEditInspector+Upscale.swift（是检查器的一段 body，不是单独的视图：
// 预览性能 ratchet 数的是 body 次数，选一段多一个视图就是多一次）。
// 不管什么：面板和对比窗口怎么摆（UpscalePresenter）、换源（VideoEditProject+Upscale）。

/// 一个正在做 / 做完还没处理的任务在检查器里的样子（只订阅这一个任务）。
struct UpscaleJobStatusView: View {
    @ObservedObject var job: UpscaleJob
    let activity: UpscaleActivity

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        let tier = job.request.tier
        VStack(alignment: .leading, spacing: 6) {
            switch job.state {
            case .running(let phase):
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(verbatim: "\(tier.title) · \(tier.detail) · \(phaseText(phase))").font(.caption)
                }
                if job.keyPrompt {
                    Text("macOS is about to ask whether SrtFlow may use your fal.ai key. Click Always Allow.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Text(String(format: L10n("%@ s · est. %@"), String(format: "%.1f", job.request.range.duration), FalMoney.text(job.request.estimate)))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { activity.remove(job) }.controlSize(.small)
                }
                Text("You can keep editing. The compare window opens when it is done.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            case .done:
                Text("Upscaled. Compare it, then decide.").font(.caption)
                HStack(spacing: 8) {
                    Button("Compare…") { activity.compare = .job(job) }
                    Button("Discard") { activity.remove(job) }
                        .instantHelp("Forget this result; the file stays on disk")
                }
                .controlSize(.small)
            case .failed(let message):
                Text(String(format: L10n("Upscale failed: %@"), message)).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Dismiss") { activity.remove(job) }.controlSize(.small)
            case .cancelled:
                Text("Upscale cancelled.").font(.caption).foregroundStyle(.secondary)
                Button("Dismiss") { activity.remove(job) }.controlSize(.small)
            }
        }
    }

    private func phaseText(_ phase: UpscalePhase) -> String {
        switch phase {
        case .preparing: return L10n("preparing")
        case .uploading: return L10n("uploading")
        case .queued(let position): return position.map { String(format: L10n("in queue (%d)"), $0) } ?? L10n("in queue")
        case .processing: return L10n("processing")
        case .downloading: return L10n("downloading")
        case .finishing: return L10n("finishing")
        }
    }
}
