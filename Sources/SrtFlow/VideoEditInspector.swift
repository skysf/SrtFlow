import SwiftUI
import SrtFlowCore

/// 右侧检查器：选中什么就调什么 —— 剪辑给变速/音量/转场/画中画，
/// 形状给颜色/线宽/大小，什么都没选给项目总览。
struct VideoEditInspectorView: View {
    @ObservedObject var project: VideoEditProject
    /// 必须直接订阅时钟：关键帧的 ◇ 实心态和数值都跟着播放头走。
    @ObservedObject var clock: PlayerClock
    var onExport: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let shape = project.selectedShape {
                    shapeSection(shape)
                } else if let clip = project.selectedClip {
                    clipSection(clip)
                } else if project.selectedClipIDs.count > 1 {
                    multiSelectionSection
                } else {
                    projectSection
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 多选

    @ViewBuilder
    private var multiSelectionSection: some View {
        Text(String(format: L10n("%d clips selected"), project.selectedClipIDs.count))
            .font(.headline)
        Text("Drag any selected clip to move them together. Export can render just the selection.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        HStack {
            Button("Export…", systemImage: "square.and.arrow.up", action: onExport)
                .instantHelp("Render just the selected clips to a video file")
            Spacer()
            Button("Delete", systemImage: "trash", role: .destructive) {
                project.deleteSelected()
            }
            .instantHelp("Remove the selected clips from the timeline", shortcut: .plain("⌫"))
        }
        .controlSize(.small)
    }

    // MARK: - 剪辑

    @ViewBuilder
    private func clipSection(_ clip: EditClip) -> some View {
        let location = project.state.location(of: clip.id)

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: clip.isAudioOnly ? "music.note" : (clip.isStillImage ? "photo" : "film"))
                    .foregroundStyle(.secondary)
                Text(clip.name)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let info = clip.info, !clip.isAudioOnly {
                Text("\(info.resolutionLabel) · \(MediaFormatting.duration(clip.assetDuration))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }

        Divider()

        // 变速：滑块 + 数值，下面直接给换算出来的时长。
        VStack(alignment: .leading, spacing: 6) {
            Text("Speed").font(.callout).fontWeight(.medium)
            HStack(spacing: 8) {
                Slider(
                    value: speedBinding(clip),
                    in: 0.1...8,
                    onEditingChanged: { editing in
                        if !editing { project.endLiveEdit() }
                    }
                )
                Text(String(format: "%.2fx", clip.speed))
                    .font(.callout)
                    .monospacedDigit()
                    .frame(width: 52, alignment: .trailing)
                Stepper("", value: stepperSpeedBinding(clip), in: 0.1...8, step: 0.05)
                    .labelsHidden()
            }
            HStack {
                Text("Duration")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.1fs", clip.timelineDuration))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }

        // 音量：视频自带的声音或音频段都能调。
        if clip.hasAudio {
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Volume").font(.callout).fontWeight(.medium)
                    Spacer()
                    Toggle("Mute", isOn: muteBinding(clip))
                        .controlSize(.small)
                }
                HStack(spacing: 6) {
                    // 滑杆走 dB 刻度：线性幅度对听感太不均匀，−20dB 在 0…2 的
                    // 线性滑杆上只占 5%，根本没法调。
                    Slider(
                        value: volumeDecibelBinding(clip),
                        in: AudioGain.minimumDB...AudioGain.maximumDB,
                        onEditingChanged: { editing in
                            if !editing { project.endLiveEdit() }
                        }
                    )
                    Text(AudioGain.label(forLinear: clip.isMuted ? 0 : clip.volume))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(clip.isMuted ? .tertiary : .secondary)
                        .frame(width: 58, alignment: .trailing)
                    Button {
                        project.setVolume(clip.id, volume: 1)
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(abs(clip.volume - 1) < 0.0001)
                    .instantHelp("Back to 0 dB (original level)")
                }
                .disabled(clip.isMuted)

                // 渐入渐出：秒数按时间线算（变速之后），0 = 关。
                fadeRow(clip, edge: .fadeIn, title: "Fade in")
                fadeRow(clip, edge: .fadeOut, title: "Fade out")
                if let note = fadeNote(clip, location: location) {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        // 转场：只在主轨且后面还有一段时有意义。
        if let location, location.track.isMain, location.clipIndex + 1 < project.state.mainClips.count {
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Transition to next clip").font(.callout).fontWeight(.medium)
                // menu 而不是 segmented：四个英文段名撑爆右栏宽度上限，
                // 整个检查器会横向溢出被裁。
                Picker("", selection: transitionBinding(clip)) {
                    ForEach(ClipTransition.allCases) { transition in
                        Text(LocalizedStringKey(transition.title)).tag(transition)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                if clip.transitionAfter != .none {
                    HStack {
                        Slider(
                            value: transitionDurationBinding(clip),
                            in: 0.1...2,
                            onEditingChanged: { editing in
                                if !editing { project.endLiveEdit() }
                            }
                        )
                        Text(String(format: "%.1fs", clip.transitionDuration))
                            .font(.caption)
                            .monospacedDigit()
                            .frame(width: 34, alignment: .trailing)
                    }
                    Text("Transitions overlap the two clips, so the total length gets shorter by the transition time.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // 批量：把这一段的转场铺到主轨所有接缝，或一键全清。
                HStack {
                    Button("Apply to All") { project.applyTransitionToAll(like: clip.id) }
                        .disabled(clip.transitionAfter == .none)
                        .instantHelp("Put this transition on every seam of the main track")
                    Spacer()
                    Button("Clear All") { project.clearAllTransitions() }
                        .disabled(!project.hasAnyTransition)
                        .instantHelp("Remove every transition on the main track")
                }
                .controlSize(.small)
            }
        }

        // 画面变换（音频段没有画面，不给）。
        if !clip.isAudioOnly {
            transformSection(clip)
        }

        // 画中画：大小 + 九宫格停靠位。
        if let location, case .overlay = location.track {
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Picture-in-picture").font(.callout).fontWeight(.medium)
                HStack {
                    Text("Size").font(.caption).foregroundStyle(.secondary)
                    Slider(
                        value: overlaySizeBinding(clip),
                        in: 0.1...1,
                        onEditingChanged: { editing in
                            if !editing { project.endLiveEdit() }
                        }
                    )
                    Text(String(format: "%.0f%%", clip.overlayFraction * 100))
                        .font(.caption)
                        .monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                }
                anchorGrid(clip)
            }
        }

        Divider()

        HStack {
            Button("Split", systemImage: "scissors") {
                project.select(clip.id, additive: false)
                project.splitAtPlayhead()
            }
            .disabled(!clip.contains(time: project.clock.time))
            .instantHelp("Cut this clip in two at the playhead", shortcut: .plain("⌘B"))
            Spacer()
            Button("Delete", systemImage: "trash", role: .destructive) {
                project.deleteSelected()
            }
            .instantHelp("Remove this clip from the timeline", shortcut: .plain("⌫"))
        }
        .controlSize(.small)
    }

    /// 一行渐变时长。数值框走 Inspector 数值框合同：文本/箭头走 `setAudioFade`
    /// （一步一记），横向拖调走 begin/live/end（整次拖动一步）。
    private func fadeRow(
        _ clip: EditClip, edge: AudioFadeEdge, title: LocalizedStringKey
    ) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            InspectorScrubbableNumberField(
                value: fadeBinding(clip, edge: edge),
                // 上限是段长：整段淡入淡出是合理诉求，比这更长没有意义。
                range: 0...max(0.1, clip.timelineDuration),
                fractionDigits: 1,
                width: 54,
                onScrubBegin: { project.beginLiveEdit() },
                onScrubChanged: { project.liveSetAudioFade(clip.id, edge: edge, seconds: $0) },
                onScrubEnd: { project.endLiveEdit() },
                onScrubCancel: { project.cancelLiveEdit() }
            )
            Text("s")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .disabled(clip.isMuted)
        .instantHelp(edge == .fadeIn
            ? LocalizedStringKey("Seconds to ramp the sound up from silence")
            : LocalizedStringKey("Seconds to ramp the sound down to silence"))
    }

    /// 主轨接缝上有转场时，那一边的渐变不生效（转场自己在做交叉淡变）——
    /// 用户设了却听不到差别，必须当场说清楚，不能让人以为是坏了。
    /// 判据与合成/导出同一个来源：`transitionOverlap`。
    private func fadeNote(_ clip: EditClip, location: ClipLocation?) -> LocalizedStringKey? {
        guard let location, location.track.isMain else { return nil }
        let fades = clip.audioFades
        let index = location.clipIndex
        let suppressedIn = index > 0
            && project.state.transitionOverlap(afterMainIndex: index - 1) > 0
            && fades.fadeIn > 0
        let suppressedOut = project.state.transitionOverlap(afterMainIndex: index) > 0
            && fades.fadeOut > 0
        guard suppressedIn || suppressedOut else { return nil }
        return "A transition already cross-fades the sound at that seam, so the fade on that side is skipped."
    }

    private func anchorGrid(_ clip: EditClip) -> some View {
        Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            ForEach(0..<3, id: \.self) { row in
                GridRow {
                    ForEach(0..<3, id: \.self) { column in
                        let anchor = OverlayAnchor.allCases.first { $0.row == row && $0.column == column }!
                        Button {
                            project.setOverlayLayout(clip.id, anchor: anchor)
                        } label: {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(clip.overlayAnchor == anchor ? Color.teal : Color.secondary.opacity(0.25))
                                .frame(width: 22, height: 15)
                        }
                        .buttonStyle(.plain)
                        .instantHelp("Dock the picture-in-picture here")
                    }
                }
            }
        }
    }

    // MARK: - 形状

    @ViewBuilder
    private func shapeSection(_ shape: ShapeAnnotation) -> some View {
        HStack(spacing: 6) {
            Image(systemName: shape.kind.icon).foregroundStyle(.secondary)
            Text(LocalizedStringKey(shape.kind.title)).fontWeight(.semibold)
            Spacer()
            ColorPicker("", selection: shapeColorBinding(shape), supportsOpacity: true)
                .labelsHidden()
        }

        Divider()

        VStack(alignment: .leading, spacing: 8) {
            labelledSlider(
                "Line width",
                value: shapeBinding(shape, \.lineWidth),
                range: 1...24,
                format: { String(format: "%.0f", $0) }
            )
            if shape.kind == .line {
                labelledSlider(
                    "Length",
                    value: shapeBinding(shape, \.width),
                    range: 0.02...1,
                    format: { String(format: "%.0f%%", $0 * 100) }
                )
                labelledSlider(
                    "Angle",
                    value: shapeBinding(shape, \.rotationDegrees),
                    range: -90...90,
                    format: { String(format: "%.0f°", $0) }
                )
            } else {
                labelledSlider(
                    shape.kind == .square ? "Side length" : "Width",
                    value: shapeBinding(shape, \.width),
                    range: 0.02...1,
                    format: { String(format: "%.0f%%", $0 * 100) }
                )
                if shape.kind == .rectangle {
                    labelledSlider(
                        "Height",
                        value: shapeBinding(shape, \.height),
                        range: 0.02...1,
                        format: { String(format: "%.0f%%", $0 * 100) }
                    )
                }
            }
        }

        Divider()

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Shows for").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.1fs", shape.duration))
                    .font(.caption)
                    .monospacedDigit()
                Stepper("", value: shapeDurationBinding(shape), in: 0.2...600, step: 0.5)
                    .labelsHidden()
            }
            Text("Drag the shape on the preview to place it; drag its block on the timeline to retime it.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Divider()

        Button("Delete Shape", systemImage: "trash", role: .destructive) {
            project.deleteShape(shape.id)
        }
        .controlSize(.small)
        .instantHelp("Remove this shape from the timeline", shortcut: .plain("⌫"))
    }

    private func labelledSlider(
        _ title: LocalizedStringKey,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: @escaping (Double) -> String
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 68, alignment: .leading)
            Slider(value: value, in: range, onEditingChanged: { editing in
                if !editing { project.endLiveEdit(rebuildsPreview: false) }
            })
            Text(format(value.wrappedValue))
                .font(.caption)
                .monospacedDigit()
                .frame(width: 40, alignment: .trailing)
        }
    }

    // MARK: - 什么都没选：项目总览

    @ViewBuilder
    private var projectSection: some View {
        Text("Project").font(.headline)

        VStack(alignment: .leading, spacing: 5) {
            summaryRow("Total length", MediaFormatting.duration(project.duration))
            summaryRow("Main track clips", "\(project.state.mainClips.count)")
            let overlayCount = project.state.overlayTracks.reduce(0) { $0 + $1.clips.count }
            if overlayCount > 0 {
                summaryRow("Picture-in-picture", "\(overlayCount)")
            }
            let audioCount = project.state.audioTracks.reduce(0) { $0 + $1.clips.count }
            if audioCount > 0 {
                summaryRow("Audio clips", "\(audioCount)")
            }
            if !project.state.shapes.isEmpty {
                summaryRow("Shapes", "\(project.state.shapes.count)")
            }
            summaryRow("Output size", "\(Int(project.renderSize.width))×\(Int(project.renderSize.height))")
        }

        Divider()

        VStack(alignment: .leading, spacing: 6) {
            Text("Subtitles").font(.callout).fontWeight(.medium)
            if let url = project.state.subtitleURL {
                HStack(spacing: 6) {
                    Image(systemName: "captions.bubble").foregroundStyle(.secondary)
                    Text(url.lastPathComponent)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        project.removeSubtitle()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .instantHelp("Unlink this subtitle file from the project")
                }
                Text("Burned in on export, using the style from the Burn In Subtitles tool.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Add a subtitle file to burn it into the exported video.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        Divider()

        // 这里曾经还有一个 Export… 按钮。删掉了（2026-08-12 用户）：
        // 窗口右上角的工具栏本来就有一个，同一个动作摆两遍只是占地方。
        // 多选那一段里的 Export… 留着 —— 那个说的是「只导出选中的这几段」，
        // 不是同一件事。
        Text("Select a clip on the timeline to adjust its speed, volume, and transition. Select a shape to recolor and resize it.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func summaryRow(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption).monospacedDigit()
        }
    }

    // MARK: - 绑定

    /// 滑块类的绑定都走 liveApply：拖动过程不炸撤销栈，松手记一步。
    private func speedBinding(_ clip: EditClip) -> Binding<Double> {
        Binding(
            get: { project.state.clip(with: clip.id)?.speed ?? clip.speed },
            set: { newValue in
                let ids = project.linkageEnabled ? project.state.linkedClipIDs(of: clip.id) : [clip.id]
                project.liveApply { state in
                    for id in ids {
                        state.update(id) { $0.speed = min(max(newValue, 0.1), 8) }
                    }
                }
            }
        )
    }

    /// 步进按钮是离散动作，直接一步一记。
    private func stepperSpeedBinding(_ clip: EditClip) -> Binding<Double> {
        Binding(
            get: { project.state.clip(with: clip.id)?.speed ?? clip.speed },
            set: { project.setSpeed(clip.id, speed: $0) }
        )
    }

    /// 滑杆读写的是 dB，落盘的仍是线性幅度 —— 换算只有 `AudioGain` 一份。
    private func volumeDecibelBinding(_ clip: EditClip) -> Binding<Double> {
        Binding(
            get: {
                let live = project.state.clip(with: clip.id)?.volume ?? clip.volume
                return AudioGain.decibels(fromLinear: live)
            },
            set: { newValue in
                let linear = AudioGain.linear(fromDecibels: newValue)
                project.liveApply { state in
                    state.update(clip.id) { $0.volume = linear }
                }
            }
        )
    }

    /// 渐变时长：读的是**存下来的**值（不是夹紧后的生效值），不然把段拉短再
    /// 拉长，框里的数字会被段长悄悄改写。
    private func fadeBinding(_ clip: EditClip, edge: AudioFadeEdge) -> Binding<Double> {
        Binding(
            get: {
                let live = project.state.clip(with: clip.id) ?? clip
                return edge == .fadeIn ? live.fadeInDuration : live.fadeOutDuration
            },
            set: { project.setAudioFade(clip.id, edge: edge, seconds: $0) }
        )
    }

    private func muteBinding(_ clip: EditClip) -> Binding<Bool> {
        Binding(
            get: { project.state.clip(with: clip.id)?.isMuted ?? clip.isMuted },
            set: { project.setMuted(clip.id, muted: $0) }
        )
    }

    private func transitionBinding(_ clip: EditClip) -> Binding<ClipTransition> {
        Binding(
            get: { project.state.clip(with: clip.id)?.transitionAfter ?? clip.transitionAfter },
            set: { project.setTransition(after: clip.id, $0) }
        )
    }

    private func transitionDurationBinding(_ clip: EditClip) -> Binding<Double> {
        Binding(
            get: { project.state.clip(with: clip.id)?.transitionDuration ?? clip.transitionDuration },
            set: { newValue in
                project.liveApply { state in
                    state.update(clip.id) { $0.transitionDuration = min(max(newValue, 0.1), 3) }
                }
            }
        )
    }

    private func overlaySizeBinding(_ clip: EditClip) -> Binding<Double> {
        Binding(
            get: { project.state.clip(with: clip.id)?.overlayFraction ?? clip.overlayFraction },
            set: { newValue in
                project.liveApply { state in
                    state.update(clip.id) { inner in
                        inner.overlayFraction = min(max(newValue, 0.1), 1)
                        // 滑块属于九宫格模型：一动就退出自由摆放，否则看不到效果。
                        inner.placement = nil
                    }
                }
            }
        )
    }

    private func shapeColorBinding(_ shape: ShapeAnnotation) -> Binding<Color> {
        Binding(
            get: {
                (project.state.shapes.first { $0.id == shape.id }?.color ?? shape.color).swiftUIColor
            },
            set: { newColor in
                project.updateShape(shape.id) { $0.color = SubtitleColor(newColor) }
            }
        )
    }

    /// 步进按钮是离散动作，每一下一步撤销。
    private func shapeDurationBinding(_ shape: ShapeAnnotation) -> Binding<Double> {
        Binding(
            get: { project.state.shapes.first { $0.id == shape.id }?.duration ?? shape.duration },
            set: { newValue in
                project.updateShape(shape.id) { $0.duration = max(0.2, newValue) }
            }
        )
    }

    private func shapeBinding(_ shape: ShapeAnnotation, _ keyPath: WritableKeyPath<ShapeAnnotation, Double>) -> Binding<Double> {
        Binding(
            get: {
                project.state.shapes.first { $0.id == shape.id }?[keyPath: keyPath]
                    ?? shape[keyPath: keyPath]
            },
            set: { newValue in
                project.liveApply { state in
                    state.updateShape(shape.id) { $0[keyPath: keyPath] = newValue }
                }
            }
        )
    }
}
