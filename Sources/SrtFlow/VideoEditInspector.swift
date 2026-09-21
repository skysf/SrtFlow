import SwiftUI
import SrtFlowCore

/// 右侧检查器：选中什么就调什么 —— 剪辑给变速/音量/转场/变换/渐变，
/// 形状给颜色/线宽/大小，文字给内容/字体/外观，什么都没选给项目总览。
struct VideoEditInspectorView: View {
    @ObservedObject var project: VideoEditProject
    /// 必须直接订阅时钟：关键帧的 ◇ 实心态和数值都跟着播放头走。
    @ObservedObject var clock: PlayerClock
    var onExport: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let seam = project.selectedTransitionSeam {
                    transitionSelectionSection(seam)
                } else if let filter = project.selectedFilter {
                    filterSection(filter)
                } else if let shape = project.selectedShape {
                    shapeSection(shape)
                } else if let overlay = project.selectedTextOverlay {
                    textSection(overlay)
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
        // 批量套用入场/出场动画：选中里有画面段就给（见 +ClipAnimation.swift）。
        let pictures = selectedPictureClipIDs
        if !pictures.isEmpty {
            multiClipAnimationSection(pictures)
            Divider()
        }
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

    // MARK: - 接缝容量

    /// 这条缝上这一**种**转场做不做得出来、最多多长。和两条渲染管线同一个判据
    ///（VideoEditTransitionHandles.swift）。
    private func seamCapacity(
        _ outgoing: EditClip, _ incoming: EditClip, _ kind: ClipTransition
    ) -> TransitionCapacity {
        TimelineState.transitionCapacity(outgoing: outgoing, incoming: incoming, kind: kind)
    }

    private func canSeamDo(
        _ outgoing: EditClip, _ incoming: EditClip, _ kind: ClipTransition
    ) -> Bool {
        if case .available = seamCapacity(outgoing, incoming, kind) { return true }
        return false
    }

    // MARK: - 转场

    /// 一条缝的转场设置。**两条路进来共用这一块**：选中了主轨上某一段（缝 =
    /// 它后面那条），或者直接点中了时间线上的转场遮罩。写两份迟早分叉。
    @ViewBuilder
    private func transitionSection(outgoing: EditClip, incoming: EditClip) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Transition to next clip").font(.callout).fontWeight(.medium)
            // 网格弹窗而不是 menu/segmented：12 种转场按族分组成卡片，
            // 悬停卡片能看动画小样（见 VideoEditTransitionPicker.swift）。
            // 这条缝放不放得下转场，和两条渲染管线**同一个判据**
            //（VideoEditTransitionHandles.swift）—— 不能出现「这里让设、
            // 成片里没有」。容量**与种类有关**：压黑不需要两段同时在画面
            // 上，零余料的缝上它能用、叠化不能用，所以逐张卡片判。
            if case .notAdjacent = seamCapacity(outgoing, incoming, .crossFade) {
                Text("No continuous footage here — a transition needs two clips that touch.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                TransitionPickerButton(
                    selection: transitionBinding(outgoing),
                    outgoingClip: outgoing,
                    incomingClip: incoming,
                    isEnabled: { canSeamDo(outgoing, incoming, $0) }
                )
                if !canSeamDo(outgoing, incoming, .crossFade) {
                    Text("These clips have no spare footage, so only Black fade works here. Trim one of them back a little to use the others.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if outgoing.transitionAfter != .none,
                   case .available(let maxDuration) = seamCapacity(outgoing, incoming, outgoing.transitionAfter) {
                    HStack {
                        Slider(
                            // 上限跟着这一**种**转场的容量走：钉死 2s 的话能
                            // 拖到一个渲染管线根本做不出来的值。
                            value: liveTransitionDurationBinding(outgoing),
                            in: 0.1...max(0.2, maxDuration),
                            onEditingChanged: { editing in
                                if !editing { project.endLiveEdit() }
                            }
                        )
                        Text(String(format: "%.1fs", outgoing.transitionDuration))
                            .font(.caption)
                            .monospacedDigit()
                            .frame(width: 34, alignment: .trailing)
                    }
                    // 两种几何两种账：磁吸把片段排成相叠，转场吃的是片段自己
                    // 的时间，总长会变短；首尾相接时片段不动，总长不变。
                    if TimelineState.needsHandles(outgoing: outgoing, incoming: incoming) {
                        Text("The transition leaves the clips where they are — the total length does not change.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Transitions overlap the two clips, so the total length gets shorter by the transition time.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            // 批量：把这一段的转场铺到主轨所有接缝，或一键全清。
            HStack {
                Button("Apply to All") { project.applyTransitionToAll(like: outgoing.id) }
                    .disabled(outgoing.transitionAfter == .none)
                    .instantHelp("Put this transition on every seam of the main track")
                Spacer()
                Button("Clear All") { project.clearAllTransitions() }
                    .disabled(!project.hasAnyTransition)
                    .instantHelp("Remove every transition on the main track")
            }
            .controlSize(.small)
        }
    }

    /// 时间线上点中转场遮罩时的检查器。
    ///
    /// 比「选中片段」那条路多一个明确的「移除转场」按钮：库里的「无」那张卡已经
    /// 删掉了（它不是一种转场），单条缝的取消现在走这个按钮、⌫、以及遮罩右键。
    @ViewBuilder
    private func transitionSelectionSection(_ seam: TransitionSeam) -> some View {
        Text(String(format: L10n("Between %@ and %@"), seam.outgoing.name, seam.incoming.name))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        transitionSection(outgoing: seam.outgoing, incoming: seam.incoming)
        Divider()
        HStack {
            Spacer()
            Button("Remove Transition", systemImage: "trash", role: .destructive) {
                project.deleteSelected()
            }
            .instantHelp("Remove this transition", shortcut: .plain("⌫"))
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
                    value: liveSpeedBinding(clip),
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
                        value: liveVolumeDecibelBinding(clip),
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
            transitionSection(
                outgoing: clip,
                incoming: project.state.mainClips[location.clipIndex + 1]
            )
        }

        // 画面变换 + 入/出场动画（音频段没有画面，两块都不给）。
        // 动画那一块接管了原来的「画面渐变」两行，见 VideoEditInspector+ClipAnimation.swift。
        if !clip.isAudioOnly {
            transformSection(clip)
            clipAnimationSection(clip, location: location)
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
                value: liveShapeBinding(shape, \.lineWidth),
                range: 1...24,
                format: { String(format: "%.0f", $0) }
            )
            if shape.kind == .line {
                labelledSlider(
                    "Length",
                    value: liveShapeBinding(shape, \.width),
                    range: 0.02...1,
                    format: { String(format: "%.0f%%", $0 * 100) }
                )
                labelledSlider(
                    "Angle",
                    value: liveShapeBinding(shape, \.rotationDegrees),
                    range: -90...90,
                    format: { String(format: "%.0f°", $0) }
                )
            } else {
                labelledSlider(
                    shape.kind == .square ? "Side length" : "Width",
                    value: liveShapeBinding(shape, \.width),
                    range: 0.02...1,
                    format: { String(format: "%.0f%%", $0 * 100) }
                )
                if shape.kind == .rectangle {
                    labelledSlider(
                        "Height",
                        value: liveShapeBinding(shape, \.height),
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

    /// 扩展文件（VideoEditInspector+Text*.swift）也用它，所以不是 private。
    /// - Parameter rebuildsPreview: 松手时要不要重建预览合成。默认 false ——
    ///   形状/文字这些叠层自己会跟着状态重画，重建只会让画面闪一下。
    ///   **画面段的属性要传 true**：它们的效果长在 AVFoundation 合成里，
    ///   不重建就永远看不到改动。
    func labelledSlider(
        _ title: LocalizedStringKey,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        rebuildsPreview: Bool = false,
        format: @escaping (Double) -> String
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 68, alignment: .leading)
            Slider(value: value, in: range, onEditingChanged: { editing in
                if !editing { project.endLiveEdit(rebuildsPreview: rebuildsPreview) }
            })
            Text(format(value.wrappedValue))
                .font(.caption)
                .monospacedDigit()
                .frame(width: 40, alignment: .trailing)
        }
    }

    // MARK: - 滤镜

    /// 选中时间线上一段滤镜时的参数区：名称 + 强度。
    ///
    /// 强度模型里是 0…1，这里显示成 0–100 —— 和「不透明度」那些百分比参数
    /// 同一个观感。0 = 原片（导出直接跳过这条 lut3d），但**不自动删段**。
    @ViewBuilder
    private func filterSection(_ filter: FilterClip) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "camera.filters").foregroundStyle(.secondary)
            Text("Filter").fontWeight(.semibold)
            Spacer()
        }

        Divider()

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Name")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 68, alignment: .leading)
                Text(LocalizedStringKey(filter.preset.title))
                    .font(.caption)
                Spacer(minLength: 0)
            }
            // 滤镜不参与 AV 合成（调色挂在播放器视图上），松手不用重建预览。
            labelledSlider(
                "Strength",
                value: liveFilterStrengthBinding(filter),
                range: 0...1,
                format: { String(format: "%.0f", $0 * 100) }
            )
        }

        Divider()

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Shows for").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.1fs", filter.duration))
                    .font(.caption)
                    .monospacedDigit()
            }
            Text("This filter grades every picture under it — text, shapes and subtitles stay untouched.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Delete", systemImage: "trash", role: .destructive) {
                    project.deleteFilter(filter.id)
                }
                .instantHelp("Remove this filter from the timeline", shortcut: .plain("⌫"))
            }
            .controlSize(.small)
        }
    }

    private func liveFilterStrengthBinding(_ filter: FilterClip) -> Binding<Double> {
        Binding(
            get: {
                project.state.filters.first { $0.id == filter.id }?.strength ?? filter.strength
            },
            set: { project.liveSetFilterStrength(filter.id, $0) }
        )
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
                summaryRow("Upper track clips", "\(overlayCount)")
            }
            let audioCount = project.state.audioTracks.reduce(0) { $0 + $1.clips.count }
            if audioCount > 0 {
                summaryRow("Audio clips", "\(audioCount)")
            }
            if !project.state.shapes.isEmpty {
                summaryRow("Shapes", "\(project.state.shapes.count)")
            }
            if !project.state.textOverlays.isEmpty {
                summaryRow("Text", "\(project.state.textOverlays.count)")
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
    private func liveSpeedBinding(_ clip: EditClip) -> Binding<Double> {
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
    private func liveVolumeDecibelBinding(_ clip: EditClip) -> Binding<Double> {
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

    private func liveTransitionDurationBinding(_ clip: EditClip) -> Binding<Double> {
        Binding(
            get: { project.state.clip(with: clip.id)?.transitionDuration ?? clip.transitionDuration },
            set: { newValue in
                project.liveApply { state in
                    state.update(clip.id) { $0.transitionDuration = min(max(newValue, 0.1), 3) }
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

    private func liveShapeBinding(_ shape: ShapeAnnotation, _ keyPath: WritableKeyPath<ShapeAnnotation, Double>) -> Binding<Double> {
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
