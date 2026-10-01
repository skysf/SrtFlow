import Foundation

// MARK: - 优化媒体：这份时间线还差哪些块、先转哪块（纯值）
//
// 管什么：从时间线状态算出要转的块的顺序（先转播放头附近的段用到的、再按时间线从头到尾），哪些源要转
//（判据在 OptimizedMediaPolicy.needsProxy）、哪些源的关键帧间隔还没探过（老工程）。
// 不管什么：真去转（OptimizedMediaCoordinator 驱动 OptimizedMediaTranscoder）、转好的块记在哪（OptimizedMediaStore）。
// 长期约束见 docs/architecture/optimized-media.md。

enum OptimizedMediaPlan {
    struct Job: Hashable, Sendable {
        var url: URL
        var chunk: Int
    }

    /// 时间线上有画面的段：主轨 + 上层视频轨，纯音频 / 静帧 / 还在转静帧的占位块不算。
    static func pictureClips(in state: TimelineState) -> [EditClip] {
        (state.mainClips + state.overlayTracks.flatMap(\.clips))
            .filter { !$0.isAudioOnly && !$0.isStillImage && !$0.needsStillConversion }
    }

    /// 关键帧间隔还不知道的源（老工程没探过）：探完写回 `info` 再来算。
    static func unknownKeyframeIntervals(in state: TimelineState) -> [URL] {
        var seen: Set<URL> = []
        var result: [URL] = []
        for clip in pictureClips(in: state) where clip.info != nil && clip.info?.keyframeInterval == nil {
            if seen.insert(clip.sourceURL).inserted { result.append(clip.sourceURL) }
        }
        return result
    }

    /// 按判据要转的源。
    static func proxySources(in state: TimelineState, decodeFPS: Double) -> Set<URL> {
        var result: Set<URL> = []
        for clip in pictureClips(in: state) {
            guard let info = clip.info,
                  OptimizedMediaPolicy.needsProxy(info: info, isStillImage: clip.isStillImage, decodeFPS: decodeFPS) else { continue }
            result.insert(clip.sourceURL)
        }
        return result
    }

    /// 还要转的块，按先后：每段按它离播放头多远（在播放头上 = 0）排，近的先；同一段按块号。已转好的、转不了的源不算。
    /// 一段用到的块两边各留一块余量（`OptimizedMediaPolicy.chunks`），裁切把手拖一拖不用马上转新块。
    static func jobs(
        in state: TimelineState, playhead: Double, decodeFPS: Double,
        ready: [URL: Set<Int>], excluded: Set<URL>
    ) -> [Job] {
        let sources = proxySources(in: state, decodeFPS: decodeFPS).subtracting(excluded)
        let clips = pictureClips(in: state)
            .filter { sources.contains($0.sourceURL) }
            .sorted { lhs, rhs in
                let left = distance(of: lhs, to: playhead), right = distance(of: rhs, to: playhead)
                return left == right ? lhs.timelineStart < rhs.timelineStart : left < right
            }
        var seen: Set<Job> = []
        var jobs: [Job] = []
        for clip in clips {
            guard let info = clip.info else { continue }
            let range = OptimizedMediaPolicy.chunks(
                sourceStart: clip.sourceStart, sourceDuration: clip.sourceDuration, sourceLength: info.duration
            )
            for chunk in range where !(ready[clip.sourceURL]?.contains(chunk) ?? false) {
                let job = Job(url: clip.sourceURL, chunk: chunk)
                if seen.insert(job).inserted { jobs.append(job) }
            }
        }
        return jobs
    }

    /// 一段离播放头多远：播放头在段里 = 0，否则到最近一端的距离。
    static func distance(of clip: EditClip, to playhead: Double) -> Double {
        max(0, clip.timelineStart - playhead, playhead - clip.timelineEnd)
    }
}
