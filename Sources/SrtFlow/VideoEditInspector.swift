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
            Spacer()
            Button("Delete", systemImage: "trash", role: .destructive) {
                project.deleteSelected()
            }
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
                Slider(
                    value: volumeBinding(clip),
                    in: 0...2,
                    onEditingChanged: { editing in
                        if !editing { project.endLiveEdit() }
                    }
                )
                .disabled(clip.isMuted)
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
                    Spacer()
                    Button("Clear All") { project.clearAllTransitions() }
                        .disabled(!project.hasAnyTransition)
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
            Spacer()
            Button("Delete", systemImage: "trash", role: .destructive) {
                project.deleteSelected()
            }
        }
        .controlSize(.small)
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

        Text("Select a clip on the timeline to adjust its speed, volume, and transition. Select a shape to recolor and resize it.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        Button("Export…", systemImage: "square.and.arrow.up", action: onExport)
            .disabled(project.state.mainClips.isEmpty)
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

    private func volumeBinding(_ clip: EditClip) -> Binding<Double> {
        Binding(
            get: { project.state.clip(with: clip.id)?.volume ?? clip.volume },
            set: { newValue in
                project.liveApply { state in
                    state.update(clip.id) { $0.volume = min(max(newValue, 0), 2) }
                }
            }
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
