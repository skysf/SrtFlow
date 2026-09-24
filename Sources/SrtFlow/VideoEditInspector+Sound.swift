import SwiftUI

// MARK: - 检查器：一段的声音（音量、渐入渐出、声音场景）
//
// 2026-09-24 从 VideoEditInspector.swift 拆出来（那个文件早已超过 600 行的上限，见
// docs/architecture/coding-standards.md），顺带加上声音场景那一块。有声音的段（音频段、视频
// 自带的声音）才有这一块，条件和以前的「音量」一样（`clip.hasAudio`）。
//
// - 音量 / 渐变的合同没变：docs/architecture/audio-fades.md、audio-volume-curve.md。
// - 声音场景：下拉是离散控件，直接 perform 一步（离散控件不许接 live 绑定，
//   checks/inspector-live-binding-wiring.sh）；滑杆走 liveApply + 松手 endLiveEdit，拖动中用
//   `previewAudioLive` 换一份 audioMix，当场听得见。合同见 docs/architecture/sound-scenes.md。

/// 选中一段有声音的剪辑时，检查器里「音量」和「声音场景」这两块。
struct ClipSoundSection: View {
    let project: VideoEditProject
    let clip: EditClip
    let location: ClipLocation?
    /// 播放头：画了曲线的段，音量滑杆显示的是播放头处线上的值（外层随时钟传进来）。
    let playhead: Double

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        VStack(alignment: .leading, spacing: 16) {
            volume
            Divider()
            SoundSceneControls(project: project, ids: [clip.id])
        }
    }

    private var volume: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Volume").font(.callout).fontWeight(.medium)
                Spacer()
                Toggle("Mute", isOn: muteBinding)
                    .controlSize(.small)
            }
            HStack(spacing: 6) {
                // 滑杆走 dB 刻度：线性幅度对听感太不均匀，−20dB 在 0…2 的
                // 线性滑杆上只占 5%，根本没法调。
                Slider(
                    value: liveVolumeDecibelBinding,
                    in: AudioGain.minimumDB...AudioGain.maximumDB,
                    onEditingChanged: { editing in
                        if !editing { project.endLiveEdit() }
                    }
                )
                Text(AudioGain.label(forLinear: clip.isMuted ? 0 : AudioGain.linear(
                    fromDecibels: volumeReferenceDecibels(clip))))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(clip.isMuted ? .tertiary : .secondary)
                    .frame(width: 58, alignment: .trailing)
                Button {
                    project.resetVolume(clip.id)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(abs(clip.volume - 1) < 0.0001 && !clip.hasVolumeCurve)
                .instantHelp(clip.hasVolumeCurve
                             ? "Remove the volume curve and go back to 0 dB"
                             : "Back to 0 dB (original level)")
            }
            .disabled(clip.isMuted)
            // 画了曲线时滑杆是「整条一起抬 / 压」：说清楚它现在管的是什么。
            if clip.hasVolumeCurve {
                Text(String(format: L10n("Volume curve with %d points. The slider raises or lowers the whole curve."),
                            clip.volumeCurve.keys.count))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 渐入渐出：秒数按时间线算（变速之后），0 = 关。
            fadeRow(edge: .fadeIn, title: "Fade in")
            fadeRow(edge: .fadeOut, title: "Fade out")
            if let note = fadeNote {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 一行渐变时长。数值框走 Inspector 数值框合同：文本/箭头走 `setAudioFade`
    /// （一步一记），横向拖调走 begin/live/end（整次拖动一步）。
    private func fadeRow(edge: AudioFadeEdge, title: LocalizedStringKey) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            InspectorScrubbableNumberField(
                value: fadeBinding(edge: edge),
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
    /// 判据与合成同一个来源：`transitionOverlap`。
    private var fadeNote: LocalizedStringKey? {
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

    // MARK: 绑定

    /// 滑杆读写的是 dB，落盘的仍是线性幅度 —— 换算只有 `AudioGain` 一份。
    ///
    /// **画了音量曲线的段**：滑杆显示播放头处（播放头不在段里就取段起点）线上的值，
    /// 拖它 = 整条曲线一起平移、形状不变（「这段整体太响」是最常见的需求，逐点拖太累）。
    /// 每一拍都从手势起手那一份算（`liveApply` 从快照重放），不在上一拍上叠加。
    private var liveVolumeDecibelBinding: Binding<Double> {
        let id = clip.id
        let fallback = clip
        let reference = volumeReferenceTime(clip)
        return Binding(
            get: {
                volumeReferenceDecibels(project.state.clip(with: id) ?? fallback)
            },
            set: { newValue in
                project.liveApply { state in
                    state.update(id) { live in
                        if live.hasVolumeCurve {
                            live.shiftWholeVolume(byDecibels: newValue - live.volumeLineDecibels(atTimeline: reference))
                        } else {
                            live.volume = AudioGain.linear(fromDecibels: newValue)
                        }
                    }
                }
            }
        )
    }

    /// 音量滑杆的参照时刻：播放头在段里就是播放头，不在就是段起点。
    private func volumeReferenceTime(_ clip: EditClip) -> Double {
        clip.contains(time: playhead) ? playhead : clip.timelineStart
    }

    /// 滑杆上显示的值（dB）：没曲线就是 `volume`，有曲线是参照时刻线上的值。
    private func volumeReferenceDecibels(_ clip: EditClip) -> Double {
        clip.volumeLineDecibels(atTimeline: volumeReferenceTime(clip))
    }

    /// 渐变时长：读的是**存下来的**值（不是夹紧后的生效值），不然把段拉短再
    /// 拉长，框里的数字会被段长悄悄改写。
    private func fadeBinding(edge: AudioFadeEdge) -> Binding<Double> {
        let id = clip.id
        let fallback = clip
        return Binding(
            get: {
                let live = project.state.clip(with: id) ?? fallback
                return edge == .fadeIn ? live.fadeInDuration : live.fadeOutDuration
            },
            set: { project.setAudioFade(id, edge: edge, seconds: $0) }
        )
    }

    private var muteBinding: Binding<Bool> {
        let id = clip.id
        let fallback = clip.isMuted
        return Binding(
            get: { project.state.clip(with: id)?.isMuted ?? fallback },
            set: { project.setMuted(id, muted: $0) }
        )
    }
}

/// 下拉菜单里选中的是哪一项。多选时各段不一样就是「多个值」（只是如实显示，不是一种场景）。
enum SoundSceneChoice: Hashable {
    case none
    case mixed
    case kind(SoundSceneKind)
}

/// 声音场景那一块：下拉 + 强度 + 两个旋钮 + 重置。单选时 `ids` 就是这一段；多选时是选中的
/// 全部有声音的段（批量套用，同入场动画）。
struct SoundSceneControls: View {
    let project: VideoEditProject
    let ids: [UUID]
    /// 多选时顶上的一行说明；单选时不要。
    var caption: String?

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        let scenes = ids.compactMap { project.state.clip(with: $0) }.map(\.soundScene)
        let choice = Self.choice(of: scenes)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Sound scene").font(.callout).fontWeight(.medium)
                Spacer(minLength: 4)
                Picker("", selection: choiceBinding(choice)) {
                    if choice == .mixed {
                        Text("Mixed").tag(SoundSceneChoice.mixed)
                    }
                    Text("None").tag(SoundSceneChoice.none)
                    ForEach(SoundSceneGroup.allCases, id: \.self) { group in
                        Section(LocalizedStringKey(group.title)) {
                            ForEach(group.kinds, id: \.self) { kind in
                                Text(LocalizedStringKey(kind.title)).tag(SoundSceneChoice.kind(kind))
                            }
                        }
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .instantHelp("Make the sound seem to come through a speaker, or from a room or outdoors. It adds space; it can’t remove echo that is already in the recording.")
            }
            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // 滑杆只在大家是同一种场景时给：不同场景的旋钮是不同的东西，混在一起拖没有意义。
            if case .kind(let kind) = choice, let first = scenes.first ?? nil {
                sliderRow("Intensity", \.amount, value: first.amount)
                sliderRow(LocalizedStringKey(kind.controls.first.title), \.first, value: first.first)
                sliderRow(LocalizedStringKey(kind.controls.second.title), \.second, value: first.second)
                HStack {
                    Spacer()
                    Button("Reset") {
                        project.perform { $0.resetSoundScene(for: ids) }
                    }
                    .controlSize(.small)
                    .disabled(scenes.allSatisfy { $0?.isDefault ?? true })
                    .instantHelp("Put this scene’s sliders back to their defaults")
                }
            }
        }
    }

    private func sliderRow(
        _ title: LocalizedStringKey, _ keyPath: WritableKeyPath<SoundScene, Double>, value: Double
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 68, alignment: .leading)
            Slider(value: liveSceneValue(keyPath), in: 0...1, onEditingChanged: { editing in
                if !editing { project.endLiveEdit() }
            })
            Text(String(format: "%.0f%%", value * 100))
                .font(.caption)
                .monospacedDigit()
                .frame(width: 40, alignment: .trailing)
        }
    }

    /// 下拉是离散控件：选中就 perform 一步（走「只换 audioMix」的快路径，画面不闪）。
    private func choiceBinding(_ current: SoundSceneChoice) -> Binding<SoundSceneChoice> {
        let ids = ids
        return Binding(
            get: { current },
            set: { value in
                switch value {
                case .mixed: return
                case .none: project.perform { $0.setSoundSceneKind(nil, for: ids) }
                case .kind(let kind): project.perform { $0.setSoundSceneKind(kind, for: ids) }
                }
            }
        )
    }

    /// 滑杆：拖动中 liveApply（从起手那份快照重放），再用 `previewAudioLive` 按此刻的状态换一份
    /// audioMix —— 当场听得见（节流到 ~20 次/秒，tap 复用，不卡）。松手 endLiveEdit 落一步。
    private func liveSceneValue(_ keyPath: WritableKeyPath<SoundScene, Double>) -> Binding<Double> {
        let ids = ids
        return Binding(
            get: {
                ids.lazy.compactMap { project.state.clip(with: $0)?.soundScene?[keyPath: keyPath] }.first ?? 0
            },
            set: { value in
                project.liveApply { $0.setSoundSceneValue(keyPath, to: value, for: ids) }
                project.previewAudioLive { _ in }
            }
        )
    }

    /// 这组段此刻是哪一项：都没有场景 = 无；都是同一种 = 那一种；否则「多个值」。
    static func choice(of scenes: [SoundScene?]) -> SoundSceneChoice {
        guard let first = scenes.first else { return .none }
        guard scenes.allSatisfy({ $0?.kind == first?.kind }) else { return .mixed }
        return first.map { .kind($0.kind) } ?? .none
    }
}
