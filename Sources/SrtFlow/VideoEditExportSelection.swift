import Foundation

// MARK: - 「只导出选中的」那一份子时间线（纯值）
//
// 管什么：只含选中的那几段的时间线（平移到 0 起点）—— 导出面板的「Selected only」。隐藏的不进、推子跟着轨走、
// 只选上层轨时升成主轨、滤镜跟着画面走（会拼紧凑时逐段映射）、帧率和画布比例跟着走。
// 不管什么：导出本身（VideoEditExportGraph）。2026-09-28 从 VideoEditModels.swift 搬出来（那个文件只许降）。
// 字幕、文字、形状不进这份子时间线（原来就是这样）。

enum TimelineExportSelection {
    /// 只含 `ids` 的时间线（平移到 0 起点），「Selected only」导出用。
    ///
    /// 只选了上层轨不选主轨时，把最下面那条上层轨升为主轨 —— 「导出单个视频」
    /// 拿到的就是完整画面而不是黑底小窗。所以**升轨的段必须丢掉自由摆放
    /// （placement）**：那是相对完整画面摆的，画面本身都不在这次导出里。
    /// 没升轨的上层轨保持原样（含摆放），所见即所得。
    static func subset(of state: TimelineState, ids: Set<UUID>) -> TimelineState {
        // 起点按**真的会导出的**段算。把隐藏的段算进来的话，藏在最前面的那一段
        // 会把整条子时间线往后推，成片开头多出一截黑场。
        let picked = ClipVisibility.visible(state.allClips.filter { ids.contains($0.id) })
        guard let earliest = picked.map(\.timelineStart).min() else {
            // 选中的全是隐藏的段：给一份空的时间线，让导出当场报「先加一段素材」。
            // 这里**不能 return state** —— 那会把整条时间线导出去，而用户点的是
            // 「只导出选中的」（同 needsStillConversion 那条：宁可拦下来说清楚，
            // 也不要「导出成功」但内容不是他要的）。
            var empty = TimelineState()
            empty.canvasRatio = state.canvasRatio
            empty.frameRate = state.frameRate
            return empty
        }

        func shifted(_ clip: EditClip) -> EditClip {
            var copy = clip
            copy.timelineStart -= earliest
            copy.transitionAfter = .none
            return copy
        }

        // 隐藏的段（单段的 V，和整轨的眼睛）一律不进这份子时间线：所见即所得，
        // 「只导出选中的」不该把用户明明藏起来的东西导出去。
        var sub = TimelineState()
        sub.mainClips = ClipVisibility.visible(state.mainClips.filter { ids.contains($0.id) }).map(shifted)
        // 推子跟着轨走：选段导出听到的必须是时间线上听到的那一份（总推子同理）。
        sub.mainVolume = state.mainVolume
        sub.masterVolume = state.masterVolume
        for lane in state.overlayTracks where !lane.isHidden {
            let clips = ClipVisibility.visible(lane.clips.filter { ids.contains($0.id) }).map(shifted)
            if !clips.isEmpty { sub.overlayTracks.append(EditLane(clips: clips, volume: lane.volume)) }
        }
        for lane in state.audioTracks where !lane.isHidden {
            let clips = ClipVisibility.visible(lane.clips.filter { ids.contains($0.id) }).map(shifted)
            if !clips.isEmpty { sub.audioTracks.append(EditLane(clips: clips, volume: lane.volume)) }
        }
        if sub.mainClips.isEmpty, !sub.overlayTracks.isEmpty {
            // 升上来的那条轨带着自己的推子当主轨。
            sub.mainVolume = sub.overlayTracks[0].volume
            sub.mainClips = sub.overlayTracks.removeFirst().clips.map { clip in
                var promoted = clip
                // 摆放/旋转/透明度和它们的动画都是相对完整画面的，画面不在
                // 这次导出里，丢掉；裁切和翻转是内容本身的属性，保留。
                promoted.placement = nil
                promoted.rotationDegrees = 0
                promoted.opacity = 1
                promoted.animation = nil
                return promoted
            }
        }
        // 滤镜跟着**画面**走，不要求用户额外选中它：它挂在时间范围上而不是挂在
        // 某个片段上，「只导出选中的」当然该带着这段画面的调色一起走。
        //
        // 两种映射，判据就是下面那句 `packMain()` 跑不跑：
        //
        // - **会拼紧凑时逐段映射**：选的段被拼拢之后，原来在第 3 段上的那截调色
        //   得跟着第 3 段挪到新位置。按时间平移是错的 —— 选了不连续的几段时，
        //   画面拼拢了、滤镜还站在原来的时刻，整个错位（2026-09-21 修）。
        //   一段滤镜可能因此裂成几截（跨了几段选中的画面），落在**没被选中的**
        //   那些时间上的部分直接丢掉：那段画面本来就不在这次导出里。
        // - **不拼紧凑时按原样平移**：那时片段保持相对位置，空隙也照样保留
        //   （上层轨可能正好在那儿有画面），所以不能按「主轨段」切。
        let willPack = sub.overlayTracks.isEmpty && sub.audioTracks.isEmpty
        if willPack, !sub.mainClips.isEmpty {
            // 拼紧凑之后每一段落在哪。和下面那句 `packMain()` 同一个函数，
            // 所以画面挪到哪儿、调色就挪到哪儿。
            let packedStarts = TimelineState.packedStarts(sub.mainClips)
            var pieces: [FilterClip] = []
            for filter in state.filters {
                // 这一段滤镜刚刚落下的最后一截：紧挨着就续上去，别裂成一堆碎块。
                var openPiece: Int?
                for (index, clip) in sub.mainClips.enumerated() {
                    // `shifted` 把起点减去了 earliest，加回来才是原时间线上的位置。
                    let originalStart = clip.timelineStart + earliest
                    let originalEnd = originalStart + clip.timelineDuration
                    let low = max(filter.timelineStart, originalStart)
                    let high = min(filter.timelineEnd, originalEnd)
                    guard high - low > 0.001 else { openPiece = nil; continue }
                    let mappedStart = packedStarts[index] + (low - originalStart)
                    if let open = openPiece,
                       abs(pieces[open].timelineEnd - mappedStart) < 0.001 {
                        pieces[open].duration += high - low
                    } else {
                        pieces.append(FilterClip(
                            preset: filter.preset, strength: filter.strength,
                            timelineStart: mappedStart, duration: high - low,
                            layer: filter.layer
                        ))
                        openPiece = pieces.count - 1
                    }
                }
            }
            sub.filters = pieces
        } else {
            let windowStart = earliest
            let windowEnd = picked.map(\.timelineEnd).max() ?? earliest
            sub.filters = state.filters.compactMap { filter in
                let start = max(filter.timelineStart, windowStart)
                let end = min(filter.timelineEnd, windowEnd)
                guard end - start > 0.0005 else { return nil }
                var copy = filter
                copy.timelineStart = start - earliest
                copy.duration = end - start
                return copy
            }
        }
        // 整层都被切没了就把层号收拢，别在子时间线里留空层。
        sub.compactFilterLayers()
        sub.canvasRatio = state.canvasRatio
        // 帧率必须跟着走：漏了这一行，选段导出会退回默认 24，与工程规格不符。
        sub.frameRate = state.frameRate
        // 只挑了主轨内容时拼紧凑（多选导出＝顺序拼接）；带着上层轨/音频时保持相对位置。
        if sub.overlayTracks.isEmpty, sub.audioTracks.isEmpty {
            sub.packMain()
        }
        return sub
    }
}
