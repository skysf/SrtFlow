import SwiftUI
import SrtFlowCore

/// 压缩和烧字幕共用的一套导出设置。
struct EncodeSettingsView: View {
    @Binding var settings: VideoEncodeSettings

    var body: some View {
        Form {
            Section("Video") {
                Picker("Encoder", selection: $settings.encoder) {
                    Text("H.264 CRF — best size").tag(VideoEncoder.softwareCRF)
                    Text("Hardware — fastest").tag(VideoEncoder.hardware)
                }
                .pickerStyle(.radioGroup)

                switch settings.encoder {
                case .softwareCRF:
                    qualityRow(
                        label: "Quality (CRF)",
                        value: Binding(
                            get: { Double(settings.crf) },
                            set: { settings.crf = Int($0.rounded()) }
                        ),
                        range: Double(VideoEncodeSettings.crfRange.lowerBound)...Double(VideoEncodeSettings.crfRange.upperBound),
                        readout: "\(settings.crf)",
                        // CRF 越小画质越好，滑杆往右走应该是「更小的文件」。
                        lowLabel: "Better quality",
                        highLabel: "Smaller file",
                        caption: LocalizedStringKey(settings.crfDescription)
                    )

                    Picker("Preset", selection: $settings.preset) {
                        ForEach(EncodePreset.allCases, id: \.self) { preset in
                            Text(preset.displayName).tag(preset)
                        }
                    }
                    Text("Slower presets spend more time looking for savings — same quality, smaller file. On an M-series chip, slow runs faster than real time for 1080p.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                case .hardware:
                    qualityRow(
                        label: "Quality",
                        value: Binding(
                            get: { Double(settings.hardwareQuality) },
                            set: { settings.hardwareQuality = Int($0.rounded()) }
                        ),
                        range: Double(VideoEncodeSettings.hardwareQualityRange.lowerBound)...Double(VideoEncodeSettings.hardwareQualityRange.upperBound),
                        readout: "\(settings.hardwareQuality)",
                        lowLabel: "Smaller file",
                        highLabel: "Better quality",
                        caption: "Uses the media engine built into the M-series chip: about ten times faster and barely touches the battery. At the same file size it looks slightly worse than the CRF encoder."
                    )
                }

                Picker("Resolution", selection: $settings.resolution) {
                    ForEach(ResolutionLimit.allCases, id: \.self) { option in
                        // displayName 是普通 String，Text(String) 不查本地化表，
                        // 必须显式包一层 LocalizedStringKey。
                        Text(LocalizedStringKey(option.displayName)).tag(option)
                    }
                }
                Picker("Frame rate", selection: $settings.frameRate) {
                    ForEach(FrameRateLimit.allCases, id: \.self) { option in
                        Text(LocalizedStringKey(option.displayName)).tag(option)
                    }
                }
                Text("Resolution and frame rate are only ever lowered, never raised.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Audio") {
                Picker("Audio", selection: $settings.audio.mode) {
                    ForEach(AudioHandling.Mode.allCases, id: \.self) { mode in
                        Text(LocalizedStringKey(mode.displayName)).tag(mode)
                    }
                }
                if settings.audio.mode == .aac {
                    Picker("Bitrate", selection: $settings.audio.kbps) {
                        ForEach(AudioHandling.availableBitrates, id: \.self) { rate in
                            Text("\(rate) kbps").tag(rate)
                        }
                    }
                } else {
                    Text("Audio is copied untouched, so nothing is lost. Sources that mp4 cannot carry (PCM, AC-3) fall back to AAC automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Output") {
                Toggle("Optimise for web streaming", isOn: $settings.fastStart)
                    .help("Adds -movflags +faststart. Leave this on for anything you upload; it changes nothing about the picture or sound.")
                Text("Moves the index to the front of the file so it can start playing before it finishes downloading.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Strip source metadata", isOn: $settings.stripMetadata)
                    .help("Adds -map_metadata -1. Useful before sharing a file; the picture and sound are untouched.")
                Text("Drops the tags the source file carries — camera model, shooting date, location, chapters.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private func qualityRow(
        label: LocalizedStringKey,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        readout: String,
        lowLabel: LocalizedStringKey,
        highLabel: LocalizedStringKey,
        caption: LocalizedStringKey
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text(readout).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: 1) {
                EmptyView()
            } minimumValueLabel: {
                Text(lowLabel).font(.caption2).foregroundStyle(.tertiary)
            } maximumValueLabel: {
                Text(highLabel).font(.caption2).foregroundStyle(.tertiary)
            }
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 把即将执行的 ffmpeg 命令原样显示出来，可以直接复制到终端里跑。
struct CommandPreview: View {
    let command: FFmpegCommand
    let executableName: String

    @State private var isExpanded = false

    private var text: String {
        ([executableName] + FFmpegArgumentBuilder.arguments(for: command))
            .map { $0.contains(" ") ? "'\($0)'" : $0 }
            .joined(separator: " ")
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                }
                .background(.quaternary.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 6))

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Label("Copy command", systemImage: "doc.on.doc")
                }
                .controlSize(.small)
            }
            .padding(.top, 4)
        } label: {
            Text("Equivalent ffmpeg command").font(.callout)
        }
    }
}
