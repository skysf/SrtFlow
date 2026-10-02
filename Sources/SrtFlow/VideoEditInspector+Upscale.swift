import SwiftUI

// MARK: - 检查器：「Upscale」一节
//
// 2026-10-02 加的，位置按 mockup：头部信息下面、Speed 上面，画面段才有。三个状态：还没做（一句说明 + Upscale…）、
// 做着 / 做完还没处理（`UpscaleJobStatusView`，只订阅那一个任务）、已经换过源（档位、日期、扣费、原片在哪、Compare… / Revert）。
// 写成检查器的一段 body 而不是单独的视图：预览性能 ratchet 数的是 body 次数，选一段多一个视图就是多一次（CI 2026-10-02 逮到的）。
// 任务的增删由检查器上的 `upscaleActivity` 订阅（很少变：开始 / 做完 / 丢弃）。合同见 docs/architecture/video-upscale.md 第三节。

extension VideoEditInspectorView {
    @ViewBuilder
    func upscaleSection(_ clip: EditClip) -> some View {
        let original = clip.upscale?.originalURL ?? clip.sourceURL
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Upscale").font(.callout).fontWeight(.medium)
                Spacer()
                Text(verbatim: "fal.ai").font(.caption2).foregroundStyle(.tertiary)
            }
            if let job = upscaleActivity.job(forOriginal: original) {
                UpscaleJobStatusView(job: job, activity: upscaleActivity)
            } else if let record = clip.upscale {
                upscaleReplaced(clip, record)
            } else {
                upscaleFresh(clip)
            }
        }
    }

    private func upscaleFresh(_ clip: EditClip) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            let canvas = VideoEditCompositionBuilder.renderSize(for: project.state)
            let short = clip.info.map { min($0.displaySize.width, $0.displaySize.height) } ?? 0
            Text(short < min(canvas.width, canvas.height)
                 ? String(format: L10n("Below the %@ canvas. Upscaling adds real detail instead of plain scaling."), "\(Int(canvas.width))×\(Int(canvas.height))")
                 : L10n("Upscaling adds real detail for a larger canvas or export."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // 没挂提示：提示是一层 NSViewRepresentable，选一段就多一次 update（性能 ratchet 数着）。
            Button("Upscale…") { upscaleActivity.present(panelFor: clip.id) }
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private func upscaleReplaced(_ clip: EditClip, _ record: ClipUpscaleRecord) -> some View {
        let tier = FalUpscaleTiers.tier(record.tier)
        let name = tier.map { "\($0.title) · \($0.detail)" } ?? record.tier
        let cost = record.costUSD.map { FalMoney.text($0) } ?? "—"
        Text(String(format: L10n("Upscaled with %@ on %@ · %@"), name, record.madeAt.formatted(date: .abbreviated, time: .omitted), cost))
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
        Text(String(format: L10n("Original %@ kept: %@"), record.originalInfo?.resolutionLabel ?? "", record.originalURL.lastPathComponent))
            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        HStack(spacing: 8) {
            Button("Compare…") { upscaleActivity.compare = .clip(clip.id) }
                .instantHelp("Play the original and the upscaled file side by side")
            Button("Revert to Original") {
                if !project.revertUpscale(clip.id) { project.notice = L10n("The original file could not be found.") }
            }
            .instantHelp("Point this clip back at the original file; the upscaled file stays on disk")
        }
        .controlSize(.small)
    }
}
