import SwiftUI

// MARK: - 对比窗口（sheet）：原片 vs upscale，分割线 / 并排，缩放，同步播放，替换 / 不替换 / 换模型
//
// 管什么：做完先弹这个（方案第 15 条），用户点「Replace Clip」才换源；「Keep Original」文件留着不换；「Try Another Model…」回面板。
// 已经换过源的段从右键 / 检查器也能进来看（原片 vs 现在用的），按钮换成「Revert to Original」。
// 默认 100%：缩到窗口大小几乎看不出差别。声音放原片的。
// 不管什么：播放器（UpscaleComparePlayback）、画面（UpscaleCompareStage）。

struct UpscaleCompareView: View {
    let project: VideoEditProject
    let target: UpscaleCompareTarget
    @Environment(\.dismiss) private var dismiss
    @StateObject private var playback: UpscaleComparePlayback
    @State private var mode = UpscaleCompareMode.wipe
    @State private var zoom = UpscaleCompareZoom.x1
    @State private var wipe: CGFloat = 0.5
    private let source: Source

    /// 两边是什么。
    struct Source {
        var originalURL: URL
        var originalLabel: String
        var upscaledURL: URL
        var upscaledSize: CGSize
        var tierName: String
        var offset: Double
        var fileName: String
        var estimate: Double?
        var elapsed: Double?
    }

    init(project: VideoEditProject, target: UpscaleCompareTarget) {
        self.project = project
        self.target = target
        let source = Self.source(project: project, target: target)
        self.source = source
        _playback = StateObject(wrappedValue: UpscaleComparePlayback(originalURL: source.originalURL, upscaledURL: source.upscaledURL, offset: source.offset))
    }

    @MainActor
    private static func source(project: VideoEditProject, target: UpscaleCompareTarget) -> Source {
        switch target {
        case .job(let job):
            let outcome = job.outcome
            let tier = job.request.tier
            return Source(
                originalURL: job.request.originalURL, originalLabel: job.request.originalInfo.resolutionLabel,
                upscaledURL: outcome?.file ?? job.request.originalURL, upscaledSize: outcome?.info.displaySize ?? job.request.originalInfo.displaySize,
                tierName: "\(tier.title) · \(tier.detail)", offset: outcome?.record.sourceOffset ?? 0,
                fileName: outcome?.file.lastPathComponent ?? "", estimate: job.request.estimate, elapsed: outcome?.elapsed
            )
        case .clip(let id):
            let clip = project.state.allClips.first { $0.id == id }
            let record = clip?.upscale
            let tier = record.flatMap { FalUpscaleTiers.tier($0.tier) }
            return Source(
                originalURL: record?.originalURL ?? clip?.sourceURL ?? URL(fileURLWithPath: "/"),
                originalLabel: record?.originalInfo?.resolutionLabel ?? "", upscaledURL: clip?.sourceURL ?? URL(fileURLWithPath: "/"),
                upscaledSize: clip?.info?.displaySize ?? CGSize(width: 1920, height: 1080),
                tierName: tier.map { "\($0.title) · \($0.detail)" } ?? (record?.tier ?? ""), offset: record?.sourceOffset ?? 0,
                fileName: clip?.sourceURL.lastPathComponent ?? "", estimate: nil, elapsed: nil
            )
        }
    }

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        VStack(spacing: 0) {
            toolbar
            UpscaleCompareStage(playback: playback, mode: mode, zoom: zoom, videoSize: source.upscaledSize, wipe: $wipe)
                .frame(minWidth: 1100, minHeight: 620)
            transport
            Divider()
            footer
        }
        .frame(minWidth: 1100)
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text(String(format: L10n("Compare · %@"), source.fileName)).font(.headline).lineLimit(1).truncationMode(.middle)
                Text(String(format: L10n("Original %@ · Upscaled %@ with %@"), source.originalLabel,
                            "\(Int(source.upscaledSize.width))×\(Int(source.upscaledSize.height))", source.tierName))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Mode", selection: $mode) {
                Text("Wipe").tag(UpscaleCompareMode.wipe)
                Text("Side by side").tag(UpscaleCompareMode.sideBySide)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 200)
            Picker("Zoom", selection: $zoom) {
                ForEach(UpscaleCompareZoom.allCases, id: \.self) { Text(verbatim: $0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 200)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var transport: some View {
        HStack(spacing: 12) {
            Button {
                playback.togglePlay()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
            }
            .instantHelp("Play or pause both sides together")
            Toggle(isOn: $playback.loops) { Image(systemName: "repeat") }
                .toggleStyle(.button)
                .instantHelp("Loop")
            Text(verbatim: "\(Self.clock(playback.time)) / \(Self.clock(playback.duration))")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Slider(value: Binding(get: { playback.time }, set: { playback.seek(to: $0) }), in: 0...max(0.01, playback.duration))
            if mode == .wipe {
                Text("Wipe").font(.caption).foregroundStyle(.secondary)
                Slider(value: Binding(get: { Double(wipe) }, set: { wipe = CGFloat($0) }), in: 0...1).frame(width: 160)
            }
            Text("Sound from the original").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(String(format: L10n("Saved as %@"), source.fileName)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if case .job(let job) = target {
                    UpscaleCostLine(job: job)
                } else {
                    Text("The original file stays where it is.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            switch target {
            case .job(let job):
                Button("Try Another Model…") {
                    UpscaleActivity.shared.remove(job)
                    if let clipID = job.clipIDs.first { UpscaleActivity.shared.present(panelFor: clipID) }
                }
                Button("Keep Original") { UpscaleActivity.shared.remove(job) }
                    .instantHelp("Do not replace the clip; the upscaled file stays on disk")
                Button("Replace Clip") { replace(job) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(job.outcome == nil)
            case .clip(let clipID):
                Button("Revert to Original") {
                    if !project.revertUpscale(clipID) { project.notice = L10n("The original file could not be found.") }
                    dismiss()
                }
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    /// 对比窗口的钟：`0:04.8`（0 秒也是 `0:00.0`，不像素材时长那样写成「—」）。
    static func clock(_ seconds: Double) -> String {
        let whole = max(0, seconds)
        return String(format: "%d:%04.1f", Int(whole) / 60, whole - Double(Int(whole) / 60 * 60))
    }

    /// 替换：工程里用这个原片、范围被盖住的段一起换源（一步撤销）；结果从活动里拿掉（文件留着）。
    private func replace(_ job: UpscaleJob) {
        guard let outcome = job.outcome else { return }
        let replacement = ClipSourceSwap.Replacement(url: outcome.file, info: outcome.info, record: outcome.record)
        let done = project.applyUpscale(replacement, to: project.clipIDs(usingPicture: job.request.originalURL))
        if done.isEmpty { project.notice = L10n("No clip in this project could be replaced; the upscaled file was kept.") }
        UpscaleActivity.shared.remove(job)
        dismiss()
    }
}

/// 「实际扣费 / 估价」那一行：账单明细几分钟后才有，单独订阅那个任务。
struct UpscaleCostLine: View {
    @ObservedObject var job: UpscaleJob

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        let estimate = FalMoney.text(job.request.estimate)
        if let actual = job.actualCost {
            Text(String(format: L10n("Charged %@ (estimated %@) · the original file stays where it is"), FalMoney.text(actual), estimate))
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Text(String(format: L10n("Estimated %@ · checking the bill · the original file stays where it is"), estimate))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
