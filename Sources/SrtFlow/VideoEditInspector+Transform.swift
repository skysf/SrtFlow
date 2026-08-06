import SwiftUI
import SrtFlowCore

// MARK: - 画面变换（Transform）
//
// 从 VideoEditInspector.swift 拆出的整个 Transform 区（单文件 ~800 行警戒线）。
// 数值框合同见 docs/architecture/inspector-scrub-number-field.md。

extension VideoEditInspectorView {
    /// 位置/缩放/旋转/不透明度/裁切/翻转，每行可单独复原，标题行整区复原。
    /// 数值框（Position/Scale/Rotation/Opacity/Crop）见
    /// `InspectorScrubbableNumberField`：Enter/失焦提交、箭头点击都是一次
    /// 一步撤销；鼠标横向拖调整段手势只记一步撤销，取消（Esc/失焦）回滚。
    /// 前四行带 ‹ ◇ ›：播放头处打/删关键帧、跳上下帧；行里有帧后改值自动落帧。
    @ViewBuilder
    func transformSection(_ clip: EditClip) -> some View {
        let live = project.state.clip(with: clip.id) ?? clip
        let isOverlay = project.isOverlayClip(clip.id)
        let resolved = live.animatedPlacement(atTimeline: clock.time, canvas: project.renderSize, isOverlay: isOverlay)
        let fallback = live.defaultPlacement(canvas: project.renderSize, isOverlay: isOverlay)

        Divider()
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Text("Transform").font(.callout).fontWeight(.medium)
                Spacer()
                keyframeCluster(live, nil)
                resetButton(disabled: !live.hasVisualTransform, help: "Reset all transform adjustments") {
                    project.resetTransform(clip.id)
                }
            }

            transformRow(
                "Position",
                isDefault: live.placement == nil && !project.hasKeyframes(live, .position),
                reset: {
                    if project.hasKeyframes(live, .position) {
                        project.clearKeyframes(clip.id, .position)
                    } else {
                        project.setPlacement(clip.id, ClipPlacement(
                            centerX: fallback.centerX,
                            centerY: fallback.centerY,
                            width: resolved.width,
                            height: resolved.height
                        ))
                    }
                },
                keyframes: (live, .position)
            ) {
                Text("X").font(.caption2).foregroundStyle(.tertiary)
                InspectorScrubbableNumberField(
                    value: positionBinding(clip, x: true),
                    range: positionRange(x: true),
                    width: 55,
                    onScrubBegin: { project.beginLiveEdit() },
                    onScrubChanged: { liveSetPosition(clip, x: true, $0) },
                    onScrubEnd: { project.endLiveEdit() },
                    onScrubCancel: { project.cancelLiveEdit() }
                )
                Text("Y").font(.caption2).foregroundStyle(.tertiary)
                InspectorScrubbableNumberField(
                    value: positionBinding(clip, x: false),
                    range: positionRange(x: false),
                    width: 55,
                    onScrubBegin: { project.beginLiveEdit() },
                    onScrubChanged: { liveSetPosition(clip, x: false, $0) },
                    onScrubEnd: { project.endLiveEdit() },
                    onScrubCancel: { project.cancelLiveEdit() }
                )
            }

            transformRow(
                "Scale",
                isDefault: live.placement == nil && !project.hasKeyframes(live, .scale),
                reset: {
                    if project.hasKeyframes(live, .scale) {
                        project.clearKeyframes(clip.id, .scale)
                    } else {
                        project.setPlacement(clip.id, ClipPlacement(
                            centerX: resolved.centerX,
                            centerY: resolved.centerY,
                            width: fallback.width,
                            height: fallback.height
                        ))
                    }
                },
                keyframes: (live, .scale)
            ) {
                InspectorScrubbableNumberField(
                    value: scaleBinding(clip),
                    range: 1...400,
                    onScrubBegin: { project.beginLiveEdit() },
                    onScrubChanged: { liveSetScale(clip, $0) },
                    onScrubEnd: { project.endLiveEdit() },
                    onScrubCancel: { project.cancelLiveEdit() }
                )
                Text("%").font(.caption2).foregroundStyle(.tertiary)
            }

            transformRow(
                "Rotation",
                isDefault: abs(live.rotationDegrees) < 0.01 && !project.hasKeyframes(live, .rotation),
                reset: {
                    if project.hasKeyframes(live, .rotation) {
                        project.clearKeyframes(clip.id, .rotation)
                    } else {
                        project.setRotation(clip.id, degrees: 0)
                    }
                },
                keyframes: (live, .rotation)
            ) {
                InspectorScrubbableNumberField(
                    value: rotationBinding(clip),
                    range: -360...360,
                    fractionDigits: 1,
                    width: 62,
                    onScrubBegin: { project.beginLiveEdit() },
                    onScrubChanged: { project.liveSetRotation(clip.id, degrees: $0) },
                    onScrubEnd: { project.endLiveEdit() },
                    onScrubCancel: { project.cancelLiveEdit() }
                )
                Text("°").font(.caption2).foregroundStyle(.tertiary)
            }

            transformRow(
                "Opacity",
                isDefault: live.opacity > 0.999 && !project.hasKeyframes(live, .opacity),
                reset: {
                    if project.hasKeyframes(live, .opacity) {
                        project.clearKeyframes(clip.id, .opacity)
                    } else {
                        project.setClipOpacity(clip.id, 1)
                    }
                },
                keyframes: (live, .opacity)
            ) {
                InspectorScrubbableNumberField(
                    value: opacityBinding(clip),
                    range: 0...100,
                    onScrubBegin: { project.beginLiveEdit() },
                    onScrubChanged: { project.liveSetClipOpacity(clip.id, $0 / 100) },
                    onScrubEnd: { project.endLiveEdit() },
                    onScrubCancel: { project.cancelLiveEdit() }
                )
                Text("%").font(.caption2).foregroundStyle(.tertiary)
            }

            transformRow("Flip", isDefault: !live.flippedHorizontally && !live.flippedVertically, reset: {
                project.setFlip(clip.id, horizontal: false, vertical: false)
            }) {
                flipToggle(clip, horizontal: true, isOn: live.flippedHorizontally)
                flipToggle(clip, horizontal: false, isOn: live.flippedVertically)
            }

            transformRow("Crop", isDefault: live.crop == nil, reset: {
                project.setCrop(clip.id, nil)
            }) {
                cropPresetMenu(clip, live: live)
            }
            HStack(spacing: 4) {
                cropField("Left", clip, live: live, \.leading)
                cropField("Right", clip, live: live, \.trailing)
                cropField("Top", clip, live: live, \.top)
                cropField("Bottom", clip, live: live, \.bottom)
            }
        }
    }

    /// 一行：左标题、右控件、（可选）关键帧簇、行尾复原。
    private func transformRow(
        _ title: LocalizedStringKey,
        isDefault: Bool,
        reset: @escaping () -> Void,
        keyframes: (EditClip, VideoEditProject.KeyframeProperty)? = nil,
        @ViewBuilder content: () -> some View
    ) -> some View {
        HStack(spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            Spacer(minLength: 2)
            content()
            if let (clip, property) = keyframes {
                keyframeCluster(clip, property)
            }
            resetButton(disabled: isDefault, help: "Reset", action: reset)
        }
    }

    /// ‹ ◇ ›：跳上一帧 / 打·删帧 / 跳下一帧。property nil 是标题行的总控
    /// （四行齐打，跳帧按全轨并集）。
    private func keyframeCluster(
        _ clip: EditClip,
        _ property: VideoEditProject.KeyframeProperty?
    ) -> some View {
        let inside = project.playheadInsideClip(clip)
        let hasKeys = property.map { project.hasKeyframes(clip, $0) }
            ?? VideoEditProject.KeyframeProperty.allCases.contains { project.hasKeyframes(clip, $0) }
        let onKey = property.map { project.isOnKeyframe(clip, $0) }
            ?? VideoEditProject.KeyframeProperty.allCases.contains { project.isOnKeyframe(clip, $0) }
        return HStack(spacing: 1) {
            Button {
                project.seekToAdjacentKeyframe(clip.id, property, forward: false)
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!hasKeys)
            .help("Previous keyframe")

            Button {
                if let property {
                    project.toggleKeyframe(clip.id, property)
                } else {
                    project.toggleAllKeyframes(clip.id)
                }
            } label: {
                Image(systemName: onKey ? "diamond.fill" : "diamond")
                    .foregroundStyle(onKey ? Color.teal : (hasKeys ? Color.primary : Color.secondary))
            }
            .disabled(!inside)
            .help("Add or remove a keyframe at the playhead")

            Button {
                project.seekToAdjacentKeyframe(clip.id, property, forward: true)
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!hasKeys)
            .help("Next keyframe")
        }
        .buttonStyle(.borderless)
        .controlSize(.mini)
        .font(.system(size: 9))
    }

    private func resetButton(disabled: Bool, help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "arrow.counterclockwise")
        }
        .buttonStyle(.borderless)
        .controlSize(.mini)
        .disabled(disabled)
        .help(help)
    }

    private func flipToggle(_ clip: EditClip, horizontal: Bool, isOn: Bool) -> some View {
        Toggle(isOn: Binding(
            get: { isOn },
            set: { newValue in
                if horizontal {
                    project.setFlip(clip.id, horizontal: newValue)
                } else {
                    project.setFlip(clip.id, vertical: newValue)
                }
            }
        )) {
            Image(systemName: horizontal ? "arrow.left.and.right" : "arrow.up.and.down")
        }
        .toggleStyle(.button)
        .buttonStyle(.borderless)
        .controlSize(.small)
        .tint(.teal)
        .help(horizontal ? "Flip horizontally" : "Flip vertically")
    }

    private static let cropPresets: [(label: String, aspect: Double)] = [
        ("16:9", 16.0 / 9), ("9:16", 9.0 / 16), ("1:1", 1), ("4:3", 4.0 / 3), ("3:4", 3.0 / 4)
    ]

    /// 比例预设：居中裁到目标宽高比；None 清掉。四个数值框随时可微调。
    private func cropPresetMenu(_ clip: EditClip, live: EditClip) -> some View {
        Menu {
            Button("None") { project.setCrop(clip.id, nil) }
            ForEach(Self.cropPresets, id: \.label) { preset in
                Button(preset.label) {
                    guard let display = live.info?.displaySize else { return }
                    project.setCrop(clip.id, ClipCrop.centered(aspect: preset.aspect, in: display))
                }
            }
        } label: {
            Text(live.crop == nil ? "None" : "Custom")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(live.info?.displaySize == nil)
    }

    private func cropField(
        _ label: LocalizedStringKey,
        _ clip: EditClip,
        live: EditClip,
        _ keyPath: KeyPath<ClipCrop, Double>
    ) -> some View {
        HStack(spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.tertiary)
            InspectorScrubbableNumberField(
                value: cropBinding(clip, live: live, keyPath),
                range: 0...45,
                width: 36,
                onScrubBegin: { project.beginLiveEdit() },
                onScrubChanged: { liveSetCrop(clip, keyPath, $0) },
                onScrubEnd: { project.endLiveEdit() },
                onScrubCancel: { project.cancelLiveEdit() }
            )
        }
    }

    /// Crop 单边：文本 Enter/失焦提交、箭头点击共用的离散绑定。
    private func cropBinding(_ clip: EditClip, live: EditClip, _ keyPath: KeyPath<ClipCrop, Double>) -> Binding<Double> {
        Binding(
            get: {
                ((project.state.clip(with: clip.id)?.crop ?? live.crop)?[keyPath: keyPath] ?? 0) * 100
            },
            set: { newValue in
                let current = project.state.clip(with: clip.id)?.crop ?? ClipCrop()
                project.setCrop(clip.id, Self.updatingCrop(current, keyPath, newValue / 100))
            }
        )
    }

    /// Crop 单边拖调：每 tick 都从手势起点的裁切基线（`liveEditOrigin`）重放，
    /// 不看拖动过程中已经变化的 `state`，四条边互相独立、不会踩到彼此。
    /// Crop 没有关键帧，规则比 Position/Scale/Rotation/Opacity 简单。
    private func liveSetCrop(_ clip: EditClip, _ keyPath: KeyPath<ClipCrop, Double>, _ newValue: Double) {
        let origin = project.liveEditOrigin?.clip(with: clip.id)?.crop ?? clip.crop ?? ClipCrop()
        project.liveSetCrop(clip.id, Self.updatingCrop(origin, keyPath, newValue / 100))
    }

    private static func updatingCrop(_ current: ClipCrop, _ keyPath: KeyPath<ClipCrop, Double>, _ fraction: Double) -> ClipCrop {
        var top = current.top
        var bottom = current.bottom
        var leading = current.leading
        var trailing = current.trailing
        switch keyPath {
        case \ClipCrop.top: top = fraction
        case \ClipCrop.bottom: bottom = fraction
        case \ClipCrop.leading: leading = fraction
        default: trailing = fraction
        }
        return ClipCrop(top: top, bottom: bottom, leading: leading, trailing: trailing)
    }

    // MARK: Transform 绑定（离散提交）

    /// 位置：摆放框中心相对画布中心的偏移，按输出像素计。
    /// 读写都按播放头此刻的**生效值**（有动画时就是插值），落帧交给 setPlacement。
    private func positionBinding(_ clip: EditClip, x: Bool) -> Binding<Double> {
        Binding(
            get: {
                guard let live = project.state.clip(with: clip.id) else { return 0 }
                let resolved = live.animatedPlacement(
                    atTimeline: clock.time,
                    canvas: project.renderSize,
                    isOverlay: project.isOverlayClip(clip.id)
                )
                return x
                    ? (resolved.centerX - 0.5) * project.renderSize.width
                    : (resolved.centerY - 0.5) * project.renderSize.height
            },
            set: { newValue in
                guard let live = project.state.clip(with: clip.id), newValue.isFinite else { return }
                var resolved = live.animatedPlacement(
                    atTimeline: clock.time,
                    canvas: project.renderSize,
                    isOverlay: project.isOverlayClip(clip.id)
                )
                if x {
                    resolved.centerX = 0.5 + newValue / max(project.renderSize.width, 1)
                } else {
                    resolved.centerY = 0.5 + newValue / max(project.renderSize.height, 1)
                }
                project.setPlacement(clip.id, resolved)
            }
        )
    }

    /// 缩放：相对默认布局宽度的百分比；改动等比作用于当前宽高（保留拉伸变形）。
    private func scaleBinding(_ clip: EditClip) -> Binding<Double> {
        Binding(
            get: {
                guard let live = project.state.clip(with: clip.id) else { return 100 }
                let isOverlay = project.isOverlayClip(clip.id)
                let resolved = live.animatedPlacement(atTimeline: clock.time, canvas: project.renderSize, isOverlay: isOverlay)
                let fallback = live.defaultPlacement(canvas: project.renderSize, isOverlay: isOverlay)
                return resolved.width / max(fallback.width, 0.0001) * 100
            },
            set: { newValue in
                guard let live = project.state.clip(with: clip.id), newValue.isFinite else { return }
                let isOverlay = project.isOverlayClip(clip.id)
                var resolved = live.animatedPlacement(atTimeline: clock.time, canvas: project.renderSize, isOverlay: isOverlay)
                let fallback = live.defaultPlacement(canvas: project.renderSize, isOverlay: isOverlay)
                let clamped = min(max(newValue, 1), 400)
                let ratio = fallback.width * clamped / 100 / max(resolved.width, 0.0001)
                resolved.width *= ratio
                resolved.height *= ratio
                project.setPlacement(clip.id, resolved)
            }
        )
    }

    private func rotationBinding(_ clip: EditClip) -> Binding<Double> {
        Binding(
            get: {
                (project.state.clip(with: clip.id) ?? clip).animatedRotation(atTimeline: clock.time)
            },
            set: { project.setRotation(clip.id, degrees: $0) }
        )
    }

    private func opacityBinding(_ clip: EditClip) -> Binding<Double> {
        Binding(
            get: {
                (project.state.clip(with: clip.id) ?? clip).animatedOpacity(atTimeline: clock.time) * 100
            },
            set: { project.setClipOpacity(clip.id, $0 / 100) }
        )
    }

    // MARK: Transform 拖调（连续写入，松手结一步撤销，取消回滚）
    //
    // Rotation/Opacity 拖调直接调 project.liveSetRotation/liveSetClipOpacity
    // 就够了（标量、已有关键帧分支）。Position/Scale 落在 ClipPlacement 的
    // 某个分量上，另外几个分量要保持手势起点的值不动，所以要从
    // `project.liveEditOrigin`（拖动开始那一刻的快照）取基线，而不是
    // 拖动过程中持续变化的 `project.state`——否则前一个 tick 写的值会被当成
    // 下一个 tick 的「未改动分量」抄回去，等效于自己在追自己。

    private func positionRange(x: Bool) -> ClosedRange<Double> {
        let extent = (x ? project.renderSize.width : project.renderSize.height) / 2
        return -extent...extent
    }

    private func liveSetPosition(_ clip: EditClip, x: Bool, _ newValue: Double) {
        guard let origin = project.liveEditOrigin?.clip(with: clip.id), newValue.isFinite else { return }
        var resolved = origin.animatedPlacement(
            atTimeline: clock.time,
            canvas: project.renderSize,
            isOverlay: project.isOverlayClip(clip.id)
        )
        if x {
            resolved.centerX = 0.5 + newValue / max(project.renderSize.width, 1)
        } else {
            resolved.centerY = 0.5 + newValue / max(project.renderSize.height, 1)
        }
        project.liveSetPlacement(clip.id, resolved)
    }

    private func liveSetScale(_ clip: EditClip, _ newValue: Double) {
        guard let origin = project.liveEditOrigin?.clip(with: clip.id), newValue.isFinite else { return }
        let isOverlay = project.isOverlayClip(clip.id)
        var resolved = origin.animatedPlacement(atTimeline: clock.time, canvas: project.renderSize, isOverlay: isOverlay)
        let fallback = origin.defaultPlacement(canvas: project.renderSize, isOverlay: isOverlay)
        let clamped = min(max(newValue, 1), 400)
        let ratio = fallback.width * clamped / 100 / max(resolved.width, 0.0001)
        resolved.width *= ratio
        resolved.height *= ratio
        project.liveSetPlacement(clip.id, resolved)
    }
}
