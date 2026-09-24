import AVFoundation

// MARK: - 余音越过段尾：挂了场景的合成音轨，最后一段后面垫一截素材
//
// 2026-09-24 探针：同一条合成音轨上两段之间的空档里 tap 照常被调、余音出得来；但**一条合成音轨最后
// 一段之后 tap 就不再被调**，`insertEmptyTimeRange` 补的空段会被静默丢掉 —— 余音在段尾一刀切断。
// 办法是在最后一段后面垫一截**真素材**：就用这一段自己的素材文件（格式天然和这条合成音轨一致，
// 不违反「一条合成音轨只装一种源格式」），tap 里 SceneTrackRenderer 按段路由，段外的输入一律当静音，
// 垫的这截内容从来不会被听见。
//
// 垫多长是**固定的** `SceneRecipe.maximumTail`（到工程结尾为止，最后一段的余音不把成片拉长）：
// 跟着场景参数变的话，拖一下旋钮就要重建合成。所以「有没有场景」算合成结构（加 / 去掉场景会重建
// 一次预览），种类和旋钮只进 audioMix（`differsOnlyInAudioMix` 按这个口径抹平）。

enum SceneTailCarrier {
    /// 给 `plan` 里挂了场景的合成音轨垫余音用的素材。`assetFor` 是 build 里那份素材缓存。
    static func pad(
        _ composition: AVMutableComposition, plan: AudioMixPlan, state: TimelineState,
        assetFor: (URL) -> AVURLAsset
    ) async {
        for lane in plan.lanes {
            let clips = lane.clipIDs.compactMap { state.clip(with: $0) }
            guard clips.contains(where: { $0.soundScene != nil }),
                  let last = clips.max(by: { $0.timelineEnd < $1.timelineEnd }),
                  let track = composition.track(withTrackID: lane.trackID) else { continue }
            let start = CMTime(seconds: last.timelineEnd, preferredTimescale: 600)
            let end = CMTime(seconds: min(last.timelineEnd + SceneRecipe.maximumTail, state.duration),
                             preferredTimescale: 600)
            guard CMTimeCompare(end, start) > 0,
                  let source = try? await assetFor(last.sourceURL).loadTracks(withMediaType: .audio).first,
                  let available = try? await source.load(.timeRange),
                  available.duration.seconds > 0.01 else { continue }
            let wanted = CMTimeSubtract(end, start)
            let piece = CMTimeRange(start: available.start, duration: CMTimeMinimum(available.duration, wanted))
            guard (try? track.insertTimeRange(piece, of: source, at: start)) != nil else { continue }
            // 素材比要垫的短：把垫进去的那截拉长（内容反正不用，只要这条轨在那段时间还活着）。
            if CMTimeCompare(piece.duration, wanted) < 0 {
                track.scaleTimeRange(CMTimeRange(start: start, duration: piece.duration), toDuration: wanted)
            }
        }
    }
}
