import SwiftUI

// MARK: - 画面段的入场 / 出场动画
//
// 两个槽（In / Out）+ 一个强度，**没有更多旋钮** —— 与文字动画同一个口径：
// 质感来自缓动曲线、幅度配比这些用户调不出来的东西，摊开只会让人调出难看的
// 结果还以为是功能不行。
//
// 这一块**接管了原来的「画面渐变」两行**（2026-09-18 拍板）：In=Fade 就是那个
// 渐变，时长也还存在同一对字段上。所以头尾只有一个地方管，用户不必在两块
// 面板之间猜哪个在生效。模型见 VideoEditClipAnimation.swift，写入见
// VideoEditProject+ClipAnimation.swift，数值框合同见
// docs/architecture/inspector-scrub-number-field.md。
//
// 单独成文件（单文件 ~800 行警戒线，同 VideoEditInspector+Transform.swift）。

extension VideoEditInspectorView {

    @ViewBuilder
    func clipAnimationSection(_ clip: EditClip, location: ClipLocation?) -> some View {
        Divider()
        VStack(alignment: .leading, spacing: 8) {
            Text("Animation").font(.callout).fontWeight(.medium)

            animationRow(clip, title: "In", edge: .fadeIn)
            animationRow(clip, title: "Out", edge: .fadeOut)

            // 只有位移/缩放类的幅度受强度控制；纯淡变/擦除调它什么都不会变。
            if liveClip(clip).presetAnimation.usesIntensity {
                labelledSlider(
                    "Intensity",
                    value: liveIntensityBinding(clip),
                    range: ClipPresetAnimation.intensityRange,
                    // 画面段的强度要重建合成才看得见（文字那边是叠层自己重画）。
                    rebuildsPreview: true,
                    format: { String(format: "%.0f%%", $0 * 100) }
                )
            }

            ForEach(animationNotes(clip, location: location), id: \.self) { note in
                // 已经是查过表的文本，走 Text 的 StringProtocol 重载（逐字显示）。
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 一行 = 一个槽：效果下拉 + 时长。效果选 None 时时长框收起来 ——
    /// 一个不生效的数字框只会让人怀疑自己是不是漏设了什么。
    @ViewBuilder
    private func animationRow(
        _ clip: EditClip, title: LocalizedStringKey, edge: FadeEdge
    ) -> some View {
        let kind = kindBinding(clip, edge: edge)
        HStack(spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            Picker("", selection: kind) {
                ForEach(ClipPresetKind.allCases) { value in
                    Text(LocalizedStringKey(value.title)).tag(value)
                }
            }
            .labelsHidden()
            .instantHelp(edge == .fadeIn
                ? LocalizedStringKey("How this clip comes in")
                : LocalizedStringKey("How this clip goes out"))
            if kind.wrappedValue != .none {
                InspectorScrubbableNumberField(
                    // `value` 是**离散**通道（打字、步进箭头），横向拖动另走
                    // 下面三个回调 —— 与文字动画同一份合同。
                    value: durationBinding(clip, edge: edge),
                    // 上限是段长：整段淡入淡出是合理诉求，比这更长没有意义。
                    range: 0.1...max(0.1, clip.timelineDuration),
                    fractionDigits: 1,
                    width: 52,
                    onScrubBegin: { project.beginLiveEdit() },
                    onScrubChanged: { project.liveSetVideoFade(clip.id, edge: edge, seconds: $0) },
                    onScrubEnd: { project.endLiveEdit() },
                    onScrubCancel: { project.cancelLiveEdit() }
                )
                Text("s").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    /// 当场说清楚几件容易让人以为"坏了"的事。
    /// 返回**已经查过表的文本**，不是 `LocalizedStringKey`：一来后者不是
    /// Hashable，`ForEach` 挂不上去；二来经 `L10n(...)` 之后本地化守卫才扫得到。
    private func animationNotes(_ clip: EditClip, location: ClipLocation?) -> [String] {
        let live = liveClip(clip)
        let preset = live.presetAnimation
        guard !preset.isEmpty else { return [] }
        var notes: [String] = []

        // 一、动画露出来的是**底下那一层**，而底下是什么随轨道不同 ——
        //     主轨底下是黑场，上层轨底下是主轨画面。不说清楚的话，用户在上层轨
        //     设了淡入却没看到"变黑"，会以为是坏了。
        let onOverlayTrack: Bool
        if let location, case .overlay = location.track { onOverlayTrack = true } else { onOverlayTrack = false }
        // 纯淡变说"淡到什么"，其余几种（位移/缩放/擦除）说"露出什么"。
        let onlyFades = preset.entrance != .wipe && preset.exit != .wipe && !preset.usesIntensity
        if onlyFades {
            notes.append(onOverlayTrack
                ? L10n("On an upper track the clip fades to and from whatever is on the track below, not to black.")
                : L10n("On the bottom track the clip fades to and from black."))
        } else {
            notes.append(onOverlayTrack
                ? L10n("On an upper track the clip animates over whatever is on the track below.")
                : L10n("On the bottom track the clip animates over black."))
        }

        // 二、入场 + 出场比这一段还长，被按比例收了。判据与声音/画面渐变共用
        //     同一个 `FadeWindow.clamped`，所以数字一定对得上。
        let window = live.presetWindow
        let asked = (preset.entrance == .none ? 0 : live.videoFadeInDuration)
            + (preset.exit == .none ? 0 : live.videoFadeOutDuration)
        if asked > live.timelineDuration + 0.005, window.fadeIn + window.fadeOut > 0 {
            notes.append(L10n("In and out are longer than this clip, so both were shortened to fit."))
        }

        // 三、主轨接缝上有转场时，那一边整个归转场管（画面渐变一直是这个口径，
        //     入/出场动画跟着同一份仲裁 `ClipPreset.effective`）。
        if let location, location.track.isMain {
            let index = location.clipIndex
            let suppressedIn = index > 0
                && project.state.transitionOverlap(afterMainIndex: index - 1) > 0
                && window.fadeIn > 0
            let suppressedOut = project.state.transitionOverlap(afterMainIndex: index) > 0
                && window.fadeOut > 0
            if suppressedIn || suppressedOut {
                notes.append(L10n("A transition already covers that seam, so the in or out on that side is skipped."))
            }
        }

        // 四、要逐帧渲染的效果会让导出先把**整段**渲一遍中间片 —— 段越长越慢，
        //     用户有权知道代价从哪来。
        if live.needsPerFrameAnimation, live.timelineDuration > 30 {
            notes.append(L10n("Animating a long clip makes exporting slower — the whole clip is re-rendered first."))
        }
        return notes
    }

    // MARK: 绑定（离散 vs 连续，合同见 VideoEditProject+ClipAnimation.swift）

    /// 面板永远读**时间线里此刻的那一份**：拖动、撤销、批量套用都会换掉
    /// 传进来的那个值拷贝。
    private func liveClip(_ clip: EditClip) -> EditClip {
        project.state.clip(with: clip.id) ?? clip
    }

    private func kindBinding(_ clip: EditClip, edge: FadeEdge) -> Binding<ClipPresetKind> {
        Binding(
            get: {
                let preset = liveClip(clip).presetAnimation
                return edge == .fadeIn ? preset.entrance : preset.exit
            },
            set: { project.setClipPresetKind([clip.id], edge: edge, kind: $0) }
        )
    }

    private func durationBinding(_ clip: EditClip, edge: FadeEdge) -> Binding<Double> {
        Binding(
            get: {
                let live = liveClip(clip)
                return edge == .fadeIn ? live.videoFadeInDuration : live.videoFadeOutDuration
            },
            set: { project.setVideoFade(clip.id, edge: edge, seconds: $0) }
        )
    }

    /// 连续写入：滑块。`labelledSlider` 松手时调 `endLiveEdit`，这里只管每一次
    /// 拖动都从手势起点的快照重放（幂等）。
    private func liveIntensityBinding(_ clip: EditClip) -> Binding<Double> {
        Binding(
            get: { liveClip(clip).presetAnimation.intensity },
            set: { project.liveSetClipPresetIntensity([clip.id], $0) }
        )
    }
}

// MARK: - 批量套用（多选时）
//
// 一节课几十张图，一张张点不现实。多选时给同一套控件，改动落到**所有选中的
// 画面段**上（纯音频段没有画面，跳过）。写入路径从第一刀起就收 `[UUID]`，
// 这里只是把界面接上去。
//
// 值不一致时**如实显示"多个值"**，不拿第一段的值冒充全体 —— 冒充的话，
// 用户看一眼以为都设好了，实际上另外十几段还是原样。

extension VideoEditInspectorView {

    /// 选中的画面段的 id（按时间线顺序；纯音频段没有画面，不参与）。
    ///
    /// 面板一路只传 **id**，值到用的时候现读（`pictureClips(_:)`）——
    /// 绑定的 getter 会在 body 重跑之前被求值（写完一次之后 Picker 立刻回读），
    /// 吃 body 里那份快照就会显示上一轮的值。与单段面板的 `liveClip` 同一条理由。
    var selectedPictureClipIDs: [UUID] {
        project.state.allClips
            .filter { project.selectedClipIDs.contains($0.id) && !$0.isAudioOnly }
            .map(\.id)
    }

    /// 现读这组 id 对应的段（已经不在时间线上的直接跳过）。
    private func pictureClips(_ ids: [UUID]) -> [EditClip] {
        ids.compactMap { project.state.clip(with: $0) }
    }

    @ViewBuilder
    func multiClipAnimationSection(_ ids: [UUID]) -> some View {
        Divider()
        VStack(alignment: .leading, spacing: 8) {
            Text("Animation").font(.callout).fontWeight(.medium)
            Text(String(format: L10n("Applies to all %d picture clips selected"), ids.count))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            multiAnimationRow(ids, title: "In", edge: .fadeIn)
            multiAnimationRow(ids, title: "Out", edge: .fadeOut)

            if pictureClips(ids).contains(where: { $0.presetAnimation.usesIntensity }) {
                labelledSlider(
                    "Intensity",
                    value: liveMultiIntensityBinding(ids),
                    range: ClipPresetAnimation.intensityRange,
                    rebuildsPreview: true,
                    format: { String(format: "%.0f%%", $0 * 100) }
                )
            }
        }
    }

    @ViewBuilder
    private func multiAnimationRow(
        _ ids: [UUID], title: LocalizedStringKey, edge: FadeEdge
    ) -> some View {
        let kind = multiKindBinding(ids, edge: edge)
        HStack(spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            Picker("", selection: kind) {
                // 只在真的不一致时才有这一项：选上任意效果之后它就消失了。
                if kind.wrappedValue == nil {
                    Text("Mixed").tag(ClipPresetKind?.none)
                }
                ForEach(ClipPresetKind.allCases) { value in
                    Text(LocalizedStringKey(value.title)).tag(ClipPresetKind?.some(value))
                }
            }
            .labelsHidden()
            .instantHelp(edge == .fadeIn
                ? LocalizedStringKey("How these clips come in")
                : LocalizedStringKey("How these clips go out"))
            if let selected = kind.wrappedValue, selected != .none {
                InspectorScrubbableNumberField(
                    value: multiDurationBinding(ids, edge: edge),
                    // 上限取最短的那一段：比它长的值在短段上会被夹紧，
                    // 数字框显示的和实际生效的就对不上了。
                    range: 0.1...max(0.1, pictureClips(ids).map(\.timelineDuration).min() ?? 0.1),
                    fractionDigits: 1,
                    width: 52,
                    onScrubBegin: { project.beginLiveEdit() },
                    onScrubChanged: { project.liveSetVideoFade(ids, edge: edge, seconds: $0) },
                    onScrubEnd: { project.endLiveEdit() },
                    onScrubCancel: { project.cancelLiveEdit() }
                )
                Text("s").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    /// 全体一致时给那个值，否则 nil（界面显示"多个值"）。**现读**，不吃快照。
    private func common<Value: Equatable>(
        _ ids: [UUID], _ value: (EditClip) -> Value
    ) -> Value? {
        let clips = pictureClips(ids)
        guard let first = clips.first.map(value) else { return nil }
        return clips.allSatisfy { value($0) == first } ? first : nil
    }

    private func multiKindBinding(
        _ ids: [UUID], edge: FadeEdge
    ) -> Binding<ClipPresetKind?> {
        Binding(
            get: {
                common(ids) { edge == .fadeIn ? $0.presetAnimation.entrance : $0.presetAnimation.exit }
            },
            set: { value in
                // 选到"多个值"那一项是空操作：它只是个如实的显示，不是一种效果。
                guard let value else { return }
                project.setClipPresetKind(ids, edge: edge, kind: value)
            }
        )
    }

    private func multiDurationBinding(_ ids: [UUID], edge: FadeEdge) -> Binding<Double> {
        Binding(
            get: {
                let duration = common(ids) {
                    edge == .fadeIn ? $0.videoFadeInDuration : $0.videoFadeOutDuration
                }
                // 不一致时显示默认值：这个框只有"写"的语义，读不回一个真值。
                return duration ?? ClipPresetAnimation.defaultDuration
            },
            set: { project.setVideoFade(ids, edge: edge, seconds: $0) }
        )
    }

    private func liveMultiIntensityBinding(_ ids: [UUID]) -> Binding<Double> {
        Binding(
            get: {
                common(ids) { $0.presetAnimation.intensity } ?? ClipPresetAnimation.default.intensity
            },
            set: { project.liveSetClipPresetIntensity(ids, $0) }
        )
    }
}
