import Foundation

// MARK: - cut_to_beat：一串片段怎么踩在拍子上（纯值）
//
// 管什么：V1 上一串接着放的片段，按拍子（时间线秒）重排：第一段的开头不动，每一段只改**出点**（从原来的入点往后用），
// 下一段接在它后面 —— 于是每个切口都落在拍子上。两种排法：
// - 不给拍数：每个切口挪到离原来那一刻最近的拍上（片段的长短大体不变，只是对齐）；
// - 给了拍数：每段正好那么多拍（素材不够长就用放得下的最多拍数）。
// 片段不能比 `minLength` 短、不能用到素材外面；一拍都放不下、或者后面已经没有拍了（音乐放完了），这一段保持原来的长度。
// 落到时间线上（`apply`）：每段改开头和长度，链接的声音跟着，后面的 V1 片段整体挪。
// 不管什么：拍子从哪来（AIBeats）、挑哪几段和参数（AIBeatCutTool）。

enum AIBeatCuts {
    struct Clip: Equatable {
        var id: UUID
        var start: Double
        var duration: Double
        /// 从入点往后最多能放多久（素材剩下的，按播放速度换算好）。
        var maxDuration: Double
    }

    struct Placed: Equatable {
        var id: UUID
        var start: Double
        var duration: Double
        /// 这一段占了几拍；没对上拍子（保持原长）是 nil。
        var beats: Int?
    }

    static let minLength = 0.4

    static func layout(_ clips: [Clip], beats: [Double], beatsPerClip: Int?) -> [Placed] {
        guard let first = clips.first else { return [] }
        var cursor = first.start
        return clips.map { clip in
            let earliest = cursor + minLength
            let latest = cursor + clip.maxDuration + 0.0005
            let candidates = beats.indices.filter { beats[$0] > earliest - 0.0005 && beats[$0] <= latest }
            var end: Double?
            if let perClip = beatsPerClip, perClip > 0 {
                // 从切口那一拍（离 cursor 最近的那一拍）往后数 perClip 拍；放不下就取放得下的最后一拍。
                let base = beats.indices.min { abs(beats[$0] - cursor) < abs(beats[$1] - cursor) }
                if let base, let target = candidates.last(where: { $0 <= base + perClip }) { end = beats[target] }
            } else {
                let wanted = cursor + clip.duration
                end = candidates.map { beats[$0] }.min { abs($0 - wanted) < abs($1 - wanted) }
            }
            let start = cursor
            let duration = end.map { $0 - start } ?? clip.duration
            let count = end.map { stop in beats.filter { $0 > start + 0.0005 && $0 <= stop + 0.0005 }.count }
            cursor = start + duration
            return Placed(id: clip.id, start: start, duration: duration, beats: count)
        }
    }

    /// 排好的落到时间线上：每段改开头和长度（入点不动）；它链接的声音跟着挪同样多、出点改同样多（不超出那段声音自己的素材）；
    /// 这一串后面的 V1 片段（和它们链接的声音）按总长的变化整体挪。音乐和别的轨不动。
    static func apply(_ placed: [Placed], in state: inout TimelineState) {
        let listed = Set(placed.map(\.id))
        let oldEnd = placed.compactMap { state.clip(with: $0.id)?.timelineEnd }.max() ?? 0
        var moved = listed
        for item in placed {
            guard let clip = state.clip(with: item.id) else { continue }
            let startDelta = item.start - clip.timelineStart
            let endDelta = item.start + item.duration - clip.timelineEnd
            state.update(item.id) { $0.timelineStart = item.start; $0.sourceDuration = item.duration * $0.speed }
            for partner in state.linkedClipIDs(of: item.id) where !listed.contains(partner) {
                moved.insert(partner)
                state.update(partner) { sound in
                    let end = sound.timelineEnd + endDelta
                    sound.timelineStart = max(0, sound.timelineStart + startDelta)
                    let wanted = max(minLength, end - sound.timelineStart) * sound.speed
                    sound.sourceDuration = min(wanted, sound.assetDuration - sound.sourceStart)
                }
            }
        }
        let newEnd = placed.map { $0.start + $0.duration }.max() ?? oldEnd
        AITimelineEdits.shiftMain(from: oldEnd, by: newEnd - oldEnd, excluding: moved, linkage: true, in: &state)
        AITimelineEdits.sortLanes(&state)
    }
}
