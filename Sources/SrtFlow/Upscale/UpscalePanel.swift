import SwiftUI

// MARK: - Upscale 面板（sheet）
//
// 管什么：选范围（这一段 / 工程里最长的那处 / 整个文件）、目标分辨率、档位，看估价，点「开始」起任务。
// 面板本身就是花钱的确认（方案第 10 条）：超过每日上限只标红不拦；没有 Key 才拦（指去设置）。
// 数都从 UpscalePanelModel 来；起的任务进 UpscaleActivity（做完弹对比窗口，不自动替换）。
// 本地化：sheet 不继承应用内语言，调用处套 `.appLanguage()`（checks/presented-views-app-language.sh）。
// 不管什么：任务本身（UpscaleJob）、换源（VideoEditProject+Upscale）。

struct UpscalePanel: View {
    let project: VideoEditProject
    let model: UpscalePanelModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = FalSettingsStore.shared
    @State private var choice: UpscaleRangeChoice
    @State private var target: FalUpscaleTarget
    @State private var tierID: String

    init(project: VideoEditProject, model: UpscalePanelModel) {
        self.project = project
        self.model = model
        _choice = State(initialValue: model.defaultChoice)
        _target = State(initialValue: model.defaultTarget)
        _tierID = State(initialValue: "bytedance-standard")
    }

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        let rows = model.rows(choice: choice, target: target)
        let range = model.range(for: choice)
        let selected = rows.first { $0.id == tierID } ?? rows[0]
        VStack(alignment: .leading, spacing: 14) {
            header
            rangeSection(range)
            targetSection
            tierSection(rows: rows, seconds: range.duration)
            footer(selected: selected, range: range)
        }
        .padding(20)
        .frame(width: 720)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Upscale Clip").font(.title3).fontWeight(.semibold)
            let info = model.originalInfo
            Text(verbatim: "\(model.clipName) · \(info.resolutionLabel) · \(Int(info.frameRate.rounded())) fps · \(MediaFormatting.duration(info.duration))")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func rangeSection(_ range: UpscaleRange) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What to upscale").font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
            if let longer = model.longerElsewhere {
                Label(
                    String(format: L10n("This file is also used by another clip in this project (%@). Upscaling the longest range covers both places."),
                           seconds(longer.duration)),
                    systemImage: "info.circle"
                )
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            }
            rangeRow(.thisClip, title: L10n("This clip only"),
                     detail: model.thisUse.map { String(format: L10n("%@ used, plus %@ of handles on each side"), seconds($0.duration), seconds(UpscaleRange.handle)) } ?? "")
            if model.uses.count > 1 {
                rangeRow(.longestUse, title: L10n("Longest use in this project (recommended)"),
                         detail: UpscaleRange.longestUse(model.uses).map { String(format: L10n("%@ used by another clip, plus handles; covers this clip too"), seconds($0.duration)) } ?? "")
            }
            rangeRow(.wholeFile, title: L10n("Whole file"), detail: L10n("Every use now and any future trim"))
        }
    }

    private func rangeRow(_ option: UpscaleRangeChoice, title: String, detail: String) -> some View {
        let seconds = model.range(for: option).duration
        return Button {
            choice = option
        } label: {
            HStack(spacing: 10) {
                Image(systemName: choice == option ? "largecircle.fill.circle" : "circle")
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).fontWeight(.medium)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(String(format: "%.1f s", seconds)).monospacedDigit()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Target resolution").font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
            Picker("Target resolution", selection: $target) {
                ForEach(FalUpscaleTarget.allCases, id: \.self) { candidate in
                    Text(verbatim: candidate.label).tag(candidate)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(target.shortSide <= model.canvasShortSide ? L10n("Matches the canvas.") : L10n("Larger than the canvas: raise the canvas size too, or the export will scale it back down."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func tierSection(rows: [UpscaleTierRow], seconds: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Model").font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: L10n("Prices for %@ of video, fal.ai rates as of %@"), String(format: "%.1f s", seconds), UpscalePanelModel.priceDate))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                tierRow(row)
            }
        }
    }

    private func tierRow(_ row: UpscaleTierRow) -> some View {
        let blurb = UpscalePanelModel.blurb(for: row.id)
        return Button {
            if row.unavailableReason == nil { tierID = row.id }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: tierID == row.id ? "largecircle.fill.circle" : "circle")
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: "\(row.tier.title) · \(row.tier.detail)").fontWeight(.medium)
                    Text(row.unavailableReason ?? L10n(blurb)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(verbatim: "\(Int(row.outputSize.width))×\(Int(row.outputSize.height))").font(.caption).foregroundStyle(.secondary)
                Text(String(format: L10n("about %d min"), FalJobProgress.minutes(row.tier.typicalSeconds)))
                    .font(.caption).foregroundStyle(.secondary).frame(width: 84, alignment: .trailing)
                Text(FalMoney.text(row.estimate)).fontWeight(.semibold).monospacedDigit().frame(width: 60, alignment: .trailing)
            }
            .contentShape(Rectangle())
            .opacity(row.unavailableReason == nil ? 1 : 0.5)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func footer(selected: UpscaleTierRow, range: UpscaleRange) -> some View {
        let spent = store.spentToday()
        let overLimit = spent + selected.estimate > store.dailyLimit + 0.0005
        Divider()
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(String(format: L10n("Saves next to the original as %@"), model.fileName(target: target, tier: selected.tier)))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if !store.hasKey {
                    Text("Add a fal.ai key in Settings → AI first.").font(.caption).foregroundStyle(.red)
                } else {
                    Text(String(format: L10n("Spent today %@ of your %@ daily limit · final cost shown after upload"), FalMoney.text(spent), FalMoney.text(store.dailyLimit)))
                        .font(.caption).foregroundStyle(overLimit ? .red : .secondary)
                }
            }
            Spacer()
            Button("Cancel") { dismiss() }
            Button(String(format: L10n("Upscale · %@"), FalMoney.text(selected.estimate))) {
                start(selected: selected, range: range)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!store.hasKey || selected.unavailableReason != nil)
        }
    }

    /// 面板上的秒数一律「6.0 s」这种写法（m:ss 对一两秒的余料不好读）。
    private func seconds(_ value: Double) -> String { String(format: "%.1f s", value) }

    private func start(selected: UpscaleTierRow, range: UpscaleRange) {
        let request = model.request(choice: choice, target: target, tier: selected.tier)
        let job = UpscaleJob(request: request, clipIDs: range.coveredClipIDs, projectGeneration: project.documentGeneration, title: model.clipName)
        UpscaleActivity.shared.add(job)
        dismiss()
    }
}
