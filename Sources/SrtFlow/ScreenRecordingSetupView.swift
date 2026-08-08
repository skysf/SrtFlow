import AppKit
import AVFoundation
import SrtFlowCore
import SwiftUI

/// 录制设置页（计划 §11.2-2）：来源、区域比例、电脑声音、麦克风、指针、点击效果。
/// 帧率不在这里选 —— 它跟随工程（显示为只读事实）。
@available(macOS 15.0, *)
struct ScreenRecordingSetupView: View {
    @ObservedObject var project: VideoEditProject
    @ObservedObject private var coordinator = ScreenRecordingCoordinator.shared

    @State private var options = ScreenRecordingOptions()
    /// 预填的保存位置：上次用过的目录（没有就是「下载」）+ 建议文件名。
    /// 用户不点 Choose 也能直接开录。
    @State private var outputURL: URL = ScreenRecordingPreferences.lastDirectory
        .appendingPathComponent(ScreenRecordingCoordinator.suggestedName())
    @State private var microphoneDevices: [(id: String, name: String)] = []
    @State private var microphoneEnabled = false
    @State private var selectedMicrophoneID: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Record Screen").font(.headline)
                Spacer()
                Button("Close") { coordinator.cancelConfiguring() }
            }
            .padding(14)

            Divider()

            Form {
                Section("Source") {
                    Picker("Record", selection: $options.sourceKind) {
                        ForEach(ScreenRecordingOptions.SourceKind.allCases) { kind in
                            Text(LocalizedStringKey(kind.title)).tag(kind)
                        }
                    }
                    if options.sourceKind == .region {
                        Picker("Aspect ratio", selection: $options.regionRatio) {
                            ForEach(RegionAspectRatio.allCases) { ratio in
                                Text(LocalizedStringKey(ratio.title)).tag(ratio)
                            }
                        }
                        Text("Drag a region on any one display. Return confirms, Escape cancels.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("Audio") {
                    Toggle("Computer audio", isOn: $options.capturesSystemAudio)
                    Text("Includes sound SrtFlow itself is playing.")
                        .font(.caption).foregroundStyle(.secondary)

                    Toggle("Microphone", isOn: $microphoneEnabled)
                    if microphoneEnabled {
                        Picker("Device", selection: $selectedMicrophoneID) {
                            ForEach(microphoneDevices, id: \.id) { device in
                                Text(device.name).tag(device.id)
                            }
                        }
                        .disabled(microphoneDevices.isEmpty)
                        if microphoneDevices.isEmpty {
                            Text("No microphone found. The screen recording will still work.")
                                .font(.caption).foregroundStyle(.orange)
                        } else {
                            // 计划 §7.4：第一版不做 AEC，同开时提示用耳机。
                            Text("Recorded to its own track. If computer audio is on too, use headphones to avoid echo — SrtFlow doesn’t cancel echo.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Pointer") {
                    Toggle("Show pointer", isOn: $options.cursor.showsCursor)
                    Toggle("Show clicks", isOn: $options.cursor.showsClicks)
                }

                Section("Output") {
                    LabeledContent("Frame rate") {
                        Text("\(project.state.frameRate.fps) fps  ·  follows the project")
                            .foregroundStyle(.secondary)
                    }
                    // 保存位置**在这里**定，不放到系统 picker 之后再问
                    // （真机首测反馈：连着被问两次，不知道走到哪一步了）。
                    LabeledContent("Save to") {
                        HStack(spacing: 6) {
                            Text(outputURL.lastPathComponent)
                                .lineLimit(1).truncationMode(.middle)
                            Button("Choose…") { chooseOutput() }
                                .controlSize(.small)
                        }
                    }
                    Text(displayDirectory)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.head)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                if let error = coordinator.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(3)
                }
                Spacer()
                Button {
                    Task { await startRecording() }
                } label: {
                    Label("Start Recording", systemImage: "record.circle")
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 460)
        .task { await loadMicrophones() }
    }

    /// 目录展示：家目录缩成 `~`，长路径更好读。
    private var displayDirectory: String {
        let path = outputURL.deletingLastPathComponent().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// 选保存位置。默认名与上次目录都沿用既有规则。
    private func chooseOutput() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.quickTimeMovie]
        // 面板打开时就停在**当前这个**位置上（预填的或用户上次改过的）。
        panel.nameFieldStringValue = outputURL.lastPathComponent
        panel.canCreateDirectories = true
        panel.message = L10n("Choose where to save this screen recording.")
        panel.directoryURL = outputURL.deletingLastPathComponent()
        if panel.runModal() == .OK, let chosen = panel.url { outputURL = chosen }
    }

    private func loadMicrophones() async {
        microphoneDevices = ScreenRecordingPermissions.microphoneDevices()
        // 记住上次的选择（计划 §7.3 的普通偏好）。设备可能已经拔了，
        // 所以要先确认它还在列表里。
        let remembered = ScreenRecordingPreferences.microphoneDeviceID
        selectedMicrophoneID = microphoneDevices.first(where: { $0.id == remembered })?.id
            ?? ScreenRecordingPermissions.defaultMicrophoneID
            ?? microphoneDevices.first?.id ?? ""
        microphoneEnabled = ScreenRecordingPreferences.microphoneEnabled
            && !microphoneDevices.isEmpty
    }

    private func startRecording() async {
        // 麦克风关着就**不触发**麦克风权限提示（计划 §11.2-3）。
        if microphoneEnabled, !selectedMicrophoneID.isEmpty {
            let granted = await ScreenRecordingPermissions.requestMicrophoneAccess()
            options.microphone = granted ? .device(id: selectedMicrophoneID) : .disabled
            if !granted {
                // 主录制照常继续，只明确告知没录到麦克风（计划 §1）。
                // 走 `report` 而不是只写 errorMessage —— 设置页马上就关了，
                // 只写在页内等于没说（复审 P1-7）。
                coordinator.report(ScreenRecordingError.microphoneNotAuthorized.localizedText)
            }
        } else {
            options.microphone = .disabled
        }
        options.outputURL = outputURL
        ScreenRecordingPreferences.microphoneEnabled = microphoneEnabled
        if microphoneEnabled, !selectedMicrophoneID.isEmpty {
            ScreenRecordingPreferences.microphoneDeviceID = selectedMicrophoneID
        }
        // **不在这里 dismiss。** 页面的显隐是 `state == .configuring` 的投影，
        // `start()` 一迁到 `.choosingSource` 就自动关了。手动 dismiss 会先把
        // 状态打回 `.idle`，`start()` 的入口 guard 随即失败，录制根本起不来。
        await coordinator.start(options: options, project: project)
    }
}

/// 本次录制 partial 的处置弹窗。文件**已经**在用户选的位置，只问要不要入轨。
@available(macOS 15.0, *)
struct ScreenRecordingPartialSheet: View {
    let result: ScreenRecordingResult
    let onDecide: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Recording is incomplete", systemImage: "exclamationmark.triangle")
                .font(.headline)

            if let reason = result.partialReason {
                Text(reason).font(.callout)
            }
            LabeledContent("Length") { Text(MediaFormatting.duration(result.duration)) }
            LabeledContent("File") {
                Text(result.mainURL.lastPathComponent).lineLimit(1).truncationMode(.middle)
            }

            Text("The file is already saved where you chose. Adding it to the timeline is optional.")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Button("Keep file only") { onDecide(false) }
                Spacer()
                Button("Add to timeline") { onDecide(true) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 420)
    }
}

/// 崩溃恢复的处置弹窗。
///
/// **必须是三选一。** 只给「保留 / 入轨」两个按钮时，早先的实现把「保留」
/// 接到了删除上 —— 按钮写着 Keep file only 却把文件删了（复审 P1-3）。
/// 删除只能是用户点了 Discard 才发生，而且要说清楚删的是哪个文件。
@available(macOS 15.0, *)
struct ScreenRecordingRecoverySheet: View {
    let recovery: PendingRecovery
    let onDecide: (RecoveryDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                recovery.kind == .microphoneOnly
                    ? "Recover microphone audio"
                    : "Recover unfinished recording",
                systemImage: "arrow.uturn.backward.circle"
            )
            .font(.headline)

            if let reason = recovery.result.partialReason {
                Text(reason).font(.callout)
            }
            if recovery.result.duration > 0 {
                LabeledContent("Length") { Text(MediaFormatting.duration(recovery.result.duration)) }
            }
            LabeledContent("File") {
                Text(recovery.result.mainURL.lastPathComponent)
                    .lineLimit(1).truncationMode(.middle)
            }

            Text(recovery.needsCommit
                 ? "Keeping it saves the file where you originally chose."
                 : "The file is already saved where you chose.")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                // 文件已经提交到用户选的位置时**不给丢弃** —— 那已经是用户的
                // 文件，一个恢复提示不该顺手删掉它。
                if recovery.allowsDiscard {
                    Button("Discard", role: .destructive) { onDecide(.discard) }
                }
                Spacer()
                Button("Keep file only") { onDecide(.keepFile) }
                // 纯音频残留**不提供入轨** —— 入轨按视频 probe，必然失败
                // （计划 §9.2-3；复审三 P1-3）。
                if recovery.kind == .recording {
                    Button("Add to timeline") { onDecide(.addToTimeline) }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(18)
        .frame(width: 440)
    }
}
