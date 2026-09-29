import AVFoundation
import Foundation

// MARK: - 定格：把素材里的一帧插进合成轨、拉长成一截静止画面
//
// 管什么：预览合成里转场余料不够时的首尾帧定格（`EditClip.renderHoldHead` / `renderHoldTail`，
// docs/architecture/transition-handles.md）—— 从素材 `sourceTime` 处取**一帧**插到 `at`，再拉长成 `duration` 秒；
// 插不进去就留一段空（露出黑底，不让后面的段整体错位）。落点和格子都走 CompositionTime。
// 从 VideoEditCompositionBuilder 拆出来（那个文件超过 600 行、只许降）。
// 不管什么：哪一截该定格、定多久（VideoEditTransitionHandles 的展开函数）；成片那边的 `tpad`（VideoEditExportGraph）。

enum CompositionHold {
    /// 定格：把素材 `sourceTime` 处的**那一帧**插到 `at`，拉长成 `duration` 秒。
    /// 插不进去（素材读不出那一帧）就留一段空 —— 那一截露出下面的黑底，不至于
    /// 让后面的段整体错位。
    static func insert(
        source: AVAssetTrack, frameAt sourceTime: Double, duration: Double,
        into track: AVMutableCompositionTrack, at: Double
    ) async {
        guard duration > 0.0005 else { return }
        let frame = CompositionTime.tick(await frameDuration(of: source))
        let target = CompositionTime.tick(duration)
        let start = CompositionTime.appendPoint(CompositionTime.tick(at), on: track)
        do {
            try track.insertTimeRange(CMTimeRange(start: CompositionTime.tick(sourceTime), duration: frame), of: source, at: start)
            track.scaleTimeRange(CMTimeRange(start: start, duration: frame), toDuration: target)
        } catch {
            CompositionTime.pad(track, to: start + target)
        }
    }

    /// 源轨一帧有多长（秒）。读不出来按 1/30。
    static func frameDuration(of source: AVAssetTrack) async -> Double {
        if let min = try? await source.load(.minFrameDuration), min.isValid, min.seconds > 0 {
            return min.seconds
        }
        return 1.0 / 30
    }
}
