import AVFoundation

// MARK: - 预览合成的 audioMix：每条合成音轨放多大声、挂什么 tap
//
// 2026-09-24 从 VideoEditCompositionBuilder.swift 原样搬出来（那个文件超过了 600 行的上限，而这一块本来
// 就是独立的一件事：合成建好之后，每条合成音轨的音量斜坡、电平表的 tap、声音场景的 tap）。builder 里
// 留着 `makeAudioMix` 这个名字转交过来。成片的声音也是这一份（ExportAudioMixdown 离线读它）。
//
// 挂了声音场景的合成音轨走另一条路：段的增益不铺进 AVFoundation，而是交给 tap 在效果之前乘
// （SceneTrackConfig / SceneTrackRenderer，VideoEditSoundSceneTrack.swift），AVFoundation 那边只放总推子。

enum AudioMixBuilder {
    /// 按 `plan` 给每条合成音轨铺音量斜坡，产出 audioMix。
    ///
    /// 两个调用方共用它：`build()` 建完合成之后调一次；只改了音量/渐变时
    /// `VideoEditProject.refreshAudioMix()` 直接调它换掉正在播的 item 上的
    /// mix（**不重建合成，画面不闪**）。两条路必须是同一份实现 —— 分开写
    /// 就会出现「拖完滑块的音量」和「重建之后的音量」不一样。
    ///
    /// 音量设定先记进一张 `GainTable`，再原样铺进 AVFoundation（乘上总推子）。电平表拿的
    /// 是**同一张**（tap 看到的是乘音量之前的采样，增益得自己乘，见 VideoEditAudioMeter.swift）。
    /// `meters` 为 nil 时（自检、成片的离线读）不挂电平表；挂了声音场景的轨照样挂场景那一份 tap
    /// （`TapContext.standaloneTap`）—— 成片的声音里要有场景。
    ///
    /// `state` 传**用户那一份**，这里自己排序、展开转场（和 `build` 插段时同一份几何）。以前三个
    /// 预览调用方传的是没展开的状态，斜坡和插进去的段对不上，转场接缝上预览的声音掉下去一截
    ///（docs/bugfixes/2026-09-24-preview-mix-ignores-transition-expansion.md）。
    static func make(
        state requested: TimelineState, plan: AudioMixPlan, meters: AudioMeterEngine? = nil
    ) -> AVMutableAudioMix? {
        guard !plan.lanes.isEmpty else { return nil }
        var state = requested
        state.sortMainClipsByStart()
        state = state.expandingTransitionHandles()
        var parameters: [AVMutableAudioMixInputParameters] = []
        let master = Float(state.masterVolume)
        for lane in plan.lanes {
            // 这条合成音轨上有没有挂声音场景的段：有的话段的增益交给 tap 在效果之前乘，推子在效果之后乘。
            let sceneSpans = SceneTrackConfig.spans(on: lane, in: state)
            var table = GainTable()
            // 同一条合成轨上，上一段的结束点就是插入游标当时的值。
            var previousEnd = 0.0
            for clipID in lane.clipIDs {
                guard let clip = state.clip(with: clipID) else { continue }
                // 轨道推子是常数，直接乘进这一段的每个设定点；总推子在铺进 AVFoundation
                // 时再乘（电平表要的是「这条轨听到的」，不含总推子）。导出那边两个都乘进
                // 同一段的 `volume=`，两条管线同一笔账（docs/architecture/audio-mixer.md）。
                let gainScale = sceneSpans == nil ? state.trackVolume(containingClip: clipID) : 1
                // 静音段不单独开分支：`addVolumeRamps` 里的音量已经是
                // `isMuted ? 0 : volume`，走同一条路才能同样享受「提前钉音量」——
                // 以前静音段是 `setVolume(0, at: 段起点)`，钉在起点上等于把
                // 1.0 → 0 的跳变留在段内，静音段的开头照样会漏出一下声音。
                // （主轨和上层轨的静音段压根不进合成，能走到这儿的只有音频轨。）
                if lane.isMainTrack, let index = state.mainClips.firstIndex(where: { $0.id == clipID }) {
                    addVolumeRamps(
                        table: &table,
                        clip: clip,
                        fades: .previewMainTrack(
                            clip: clip,
                            transitionBefore: index > 0 ? state.transitionOverlap(afterMainIndex: index - 1) : 0,
                            transitionAfter: state.transitionOverlap(afterMainIndex: index)
                        ),
                        previousEnd: previousEnd,
                        gainScale: gainScale
                    )
                } else {
                    // 上层视频轨和音频轨都没有轨内转场，用户设的渐变直接生效。
                    addVolumeRamps(
                        table: &table, clip: clip, fades: clip.audioFades, previousEnd: previousEnd,
                        gainScale: gainScale
                    )
                }
                previousEnd = clip.timelineEnd
            }
            let params = AVMutableAudioMixInputParameters()
            params.trackID = lane.trackID
            if let sceneSpans, let first = lane.clipIDs.first {
                // 挂了场景的轨：AVFoundation 只放总推子（常数，空档里也不变）；段增益 + 效果 + 轨道推子
                // 都在 tap 里（电平表看的是 tap 处理完的声音，所以它那张增益表是空的 = 1）。
                params.setVolume(master, at: .zero)
                let scenes = SceneTrackConfig(
                    spans: sceneSpans, gains: table.sampler(),
                    post: Float(state.trackVolume(containingClip: first))
                )
                params.audioTapProcessor = meters.map {
                    $0.tap(trackID: lane.trackID, key: meterKey(for: lane, in: state), table: GainTable(),
                           master: master, scenes: scenes)
                } ?? TapContext.standaloneTap(scenes: scenes)
            } else {
                table.apply(to: params, scale: master)
                if let meters {
                    params.audioTapProcessor = meters.tap(
                        trackID: lane.trackID, key: meterKey(for: lane, in: state), table: table, master: master
                    )
                }
            }
            parameters.append(params)
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        return mix
    }

    /// 一条合成音轨属于哪条时间线轨（电平表按它归到轨道头那一条表上；主轨的 A/B
    /// 两条合成轨归到同一条）。
    private static func meterKey(for lane: AudioMixPlan.Lane, in state: TimelineState) -> MeterKey {
        guard let first = lane.clipIDs.first, let location = state.location(of: first),
              let key = TimelineRowHeights.key(for: location.track, in: state) else { return .track(.main) }
        return .track(key)
    }

    /// 剪辑范围内的恒定音量；两端按 `fades` 做线性斜坡。
    ///
    /// `fades` 里已经把「用户设的渐入渐出」和「转场重叠区的交叉淡变」仲裁完了
    /// （`AudioFadeWindow.previewMainTrack`），这里只管照着铺斜坡 —— 别在这个
    /// 函数里再判断转场，两处判断迟早会分叉。
    ///
    /// `previousEnd` 是**同一条合成轨上**上一段的结束点，用来给下面的「提前钉
    /// 音量」找落点，不能越过它去动上一段的尾巴。
    static func addVolumeRamps(
        table: inout GainTable,
        clip: EditClip,
        fades: AudioFadeWindow,
        previousEnd: Double,
        gainScale: Double
    ) {
        // 画了音量曲线的段走折线表（与导出同一张），没画的段一行不变地走老路。
        if clip.hasVolumeCurve {
            addCurveRamps(
                table: &table, clip: clip, fades: fades, previousEnd: previousEnd, gainScale: gainScale
            )
            return
        }
        let volume = Float((clip.isMuted ? 0 : clip.volume) * gainScale)
        let fadeIn: Double? = fades.fadeIn > 0 ? fades.fadeIn : nil
        let fadeOut: Double? = fades.fadeOut > 0 ? fades.fadeOut : nil

        // 段起点**之前**先把音量钉到「这一段该从多少起步」，而且钉得越早越好。
        //
        // AVFoundation 的混音器不会硬切增益：第一条斜坡之前的音量默认是 **1.0**，
        // 于是「起点音量 0」的渐入在段起点处是一个 1.0 → 0 的跳变，混音器会把它
        // 按**一个渲染缓冲区**平滑过去（de-zipper），结果是一条从满音量滑到 0 的
        // 下坡贴在渐入最前面 —— 听感就是渐入开头「砰」的一下。
        //
        // 关键在于**缓冲区多长由播放路径决定**：离线的 AVAssetReader 约 17ms，
        // 实时的 AVPlayer 能到 ~90ms（4096 帧 @44.1kHz）。所以任何**固定**的提前量
        // 都是在赌缓冲区大小 —— 上一版赌的 50ms 在离线自检里够用（自检因此全绿），
        // 在真实预览里不够（2026-08-12 用户报告：BG2 开头仍有短促爆音）。
        // 这个下坡**从 1.0 起步，与用户设的音量无关**，所以音量调得越低越突出。
        //
        // 不赌了：钉到**同一条合成轨上上一段结束的地方**。那里到本段起点之间全是
        // 空段（静音），钉多早都不会碰到别人的声音，跳变爱平滑多久平滑多久。
        // 一条轨的第一段钉在 0 —— 于是每条合成轨从第一帧起就有确定的音量，
        // 再也不会撞上默认的 1.0。
        //
        // 段紧挨着上一段时没有空档可用（pin == 起点），跳变只能落在段内，但那是
        // 「上一段音量 → 本段音量」，两端都是用户定的值，不是默认的 1.0。
        //
        // 钉的值分两种：有渐入的钉 0，没渐入的钉 body 音量本身。一律钉 0 的话，
        // 所有段都会被 de-zipper 加上一个软起音 —— 修一个 bug 造一个新的。
        let pin = min(previousEnd, clip.timelineStart)
        table.set(fadeIn == nil ? volume : 0, at: time(pin))

        var bodyStart = clip.timelineStart
        var bodyEnd = clip.timelineEnd
        if let fadeIn, fadeIn > 0 {
            table.ramp(
                from: 0, to: volume,
                range: CMTimeRange(start: time(clip.timelineStart), end: time(clip.timelineStart + fadeIn))
            )
            bodyStart += fadeIn
        }
        if let fadeOut, fadeOut > 0 { bodyEnd -= fadeOut }
        if bodyEnd > bodyStart {
            table.ramp(
                from: volume, to: volume,
                range: CMTimeRange(start: time(bodyStart), end: time(bodyEnd))
            )
        }
        if let fadeOut, fadeOut > 0 {
            table.ramp(
                from: volume, to: 0,
                range: CMTimeRange(start: time(clip.timelineEnd - fadeOut), end: time(clip.timelineEnd))
            )
        }
    }

    /// 画了音量曲线的段：按 `VolumeCurveSampling.breakpoints` 那张折线表铺一串
    /// 线性斜坡，再乘上渐入渐出和推子。
    ///
    /// 折线表是**导出也在用的那一张**（`aeval` 里是同一组点），所以两条管线
    /// 之间没有「弦 vs 曲线」的差。唯一要额外细分的是渐变窗口：线性渐变 × 线性
    /// 折线是二次曲线，窗口里按 `fadeSubdivisions` 等分取点（误差远小于 0.1 dB）。
    ///
    /// 「提前钉音量」那条规矩原样照搬（见 `addVolumeRamps` 的长注释）：钉点仍是
    /// 同一条合成轨上一段的结束处，钉的值是这一段起点真正的增益。
    private static func addCurveRamps(
        table: inout GainTable,
        clip: EditClip,
        fades: AudioFadeWindow,
        previousEnd: Double,
        gainScale: Double
    ) {
        let span = clip.timelineDuration
        let curve = VolumeCurveSampling.breakpoints(for: clip)
        guard span > 0, !curve.isEmpty else { return }

        var times = curve.map(\.time)
        for (start, length) in [(0.0, fades.fadeIn), (span - fades.fadeOut, fades.fadeOut)] where length > 0 {
            for step in 0...fadeSubdivisions {
                times.append(start + length * Double(step) / Double(fadeSubdivisions))
            }
        }
        times = times.map { min(max($0, 0), span) }.sorted()

        func gain(_ offset: Double) -> Float {
            let envelope = fades.linearEnvelope(atElapsed: offset, span: span)
            return Float(VolumeCurveSampling.gain(at: offset, in: curve) * envelope * gainScale)
        }

        let pin = min(previousEnd, clip.timelineStart)
        table.set(gain(0), at: time(pin))
        // 相邻两点落在同一个 1/600 秒格子里就并掉（零长斜坡 AVFoundation 不认）。
        var last: (time: CMTime, gain: Float) = (time(clip.timelineStart), gain(0))
        for offset in times {
            let at = time(clip.timelineStart + offset)
            let value = gain(offset)
            guard CMTimeCompare(at, last.time) > 0 else {
                last.gain = value
                continue
            }
            table.ramp(from: last.gain, to: value, range: CMTimeRange(start: last.time, end: at))
            last = (at, value)
        }
    }

    /// 渐变窗口里细分多少份（见 `addCurveRamps`）。
    static let fadeSubdivisions = 16

    private static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: max(0, seconds), preferredTimescale: 600)
    }
}
