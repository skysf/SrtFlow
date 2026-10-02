import SwiftUI

// MARK: - 检查器里的「Upscale」一节
//
// 管什么：选中一段画面时，头部信息下面那一小节（mockup：三个状态）。还没做：一句说明 + 「Upscale…」；做着：阶段、估价、取消
//（`UpscaleJobStatusView` 单独订阅那个任务，阶段每变一次只有它重算）；做完还没处理：「Compare…」；已经换过源：用了哪个档位、
// 花了多少、原片在哪、「Compare…」「Revert to Original」。只订阅 `UpscaleActivity`（任务的增删），不订阅工程。
// 不管什么：面板和对比窗口怎么摆（UpscalePresenter）、换源（VideoEditProject+Upscale）。

struct UpscaleInspectorSection: View {
    let project: VideoEditProject
    let clip: EditClip
    @ObservedObject private var activity = UpscaleActivity.shared

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        let original = clip.upscale?.originalURL ?? clip.sourceURL
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Upscale").font(.callout).fontWeight(.medium)
                Spacer()
                Text(verbatim: "fal.ai").font(.caption2).foregroundStyle(.tertiary)
            }
            if let job = activity.job(forOriginal: original) {
                UpscaleJobStatusView(job: job, activity: activity)
            } else if let record = clip.upscale {
                replaced(record)
            } else {
                fresh
            }
        }
    }

    private var fresh: some View {
        VStack(alignment: .leading, spacing: 6) {
            let canvas = VideoEditCompositionBuilder.renderSize(for: project.state)
            let short = clip.info.map { min($0.displaySize.width, $0.displaySize.height) } ?? 0
            Text(short < min(canvas.width, canvas.height)
                 ? String(format: L10n("Below the %@ canvas. Upscaling adds real detail instead of plain scaling."), "\(Int(canvas.width))×\(Int(canvas.height))")
                 : L10n("Upscaling adds real detail for a larger canvas or export."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Upscale…") { activity.present(panelFor: clip.id) }
                .controlSize(.small)
                .instantHelp("Send this clip to fal.ai for a sharper, larger version")
        }
    }

    @ViewBuilder
    private func replaced(_ record: ClipUpscaleRecord) -> some View {
        let tier = FalUpscaleTiers.tier(record.tier)
        let name = tier.map { "\($0.title) · \($0.detail)" } ?? record.tier
        let cost = record.costUSD.map { FalMoney.text($0) } ?? "—"
        Text(String(format: L10n("Upscaled with %@ on %@ · %@"), name, record.madeAt.formatted(date: .abbreviated, time: .omitted), cost))
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
        Text(String(format: L10n("Original %@ kept: %@"), record.originalInfo?.resolutionLabel ?? "", record.originalURL.lastPathComponent))
            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        HStack(spacing: 8) {
            Button("Compare…") { activity.compare = .clip(clip.id) }
                .instantHelp("Play the original and the upscaled file side by side")
            Button("Revert to Original") {
                if !project.revertUpscale(clip.id) { project.notice = L10n("The original file could not be found.") }
            }
            .instantHelp("Point this clip back at the original file; the upscaled file stays on disk")
        }
        .controlSize(.small)
    }
}

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
