import AVFoundation
import Foundation

// MARK: - 把一段画面插进合成轨（原片一片，或优化媒体的几块首尾相接）
//
// 管什么：`VideoEditCompositionBuilder` 插画面的那一步：轨内连续、落点之前补空段、首尾定格、变速拉伸。源是原片就一片插完；
// 这一段用到的优化媒体块都转好了就按块插几片（块之间首尾相接、同一套编码参数，拼起来和一个文件没区别），差一块、
// 或者哪一片插不进去（块文件被清了）就退回原片。**段的时间账一个数都不动**：起止、变速、定格都按段算，和插原片一样
//（docs/architecture/optimized-media.md 第二节第 10 条）。
// 不管什么：哪些块转好了（OptimizedMediaLookup）、块怎么转（OptimizedMediaTranscoder）、画面怎么摆（builder 的 fittingTransform）。
// 从 VideoEditCompositionBuilder 拆出来（那个文件超过 600 行、只许降）。

enum CompositionClipInsert {
    /// 画面的一片从哪条源轨取：`offset` = 这片自己的 0 秒对应源的多少秒；`covers` = 它盖住的源时间。
    struct Piece {
        var track: AVAssetTrack
        var offset: Double
        var covers: ClosedRange<Double>
    }

    /// 插进去了就返回画面几何该按哪条源轨算（原片，或第一块代理 —— 4K 的代理减了半，尺寸要按它自己的，
    /// 裁切 / 摆放都是归一化的，按代理的尺寸算出来的画面和原片一样）。nil = 这段插不进去。
    ///
    /// 截取范围要收口到**源轨自己的范围**里（素材比标的时长短一小截时按视频时长去截会越界抛错）。
    /// **首尾定格**（`renderHoldHead` / `renderHoldTail`，只有渲染副本里转场余料不够的主轨段才有）：把首帧 / 尾帧插进来
    /// 再拉长成定格。导出那边是 `tpad` 复制首尾帧 + 补静音，同一笔账（VideoEditExportGraph）。
    /// `at`：落点（时间线秒），不传就是段自己的起点；主轨接缝的零头会传前一段的末尾。
    static func insert(
        original: AVAssetTrack,
        proxies: [Int: AVAssetTrack]?,
        clip: EditClip,
        into track: AVMutableCompositionTrack,
        cursor: inout Double,
        at: Double? = nil
    ) async -> AVAssetTrack? {
        let at = at ?? clip.timelineStart
        let holdHead = clip.renderHoldHead
        let holdTail = clip.renderHoldTail

        let trackRange = (try? await original.load(.timeRange))
            ?? CMTimeRange(start: .zero, duration: CompositionTime.tick(clip.assetDuration))
        let trackEnd = trackRange.end.seconds
        let start = max(clip.renderSourceStart, max(0, trackRange.start.seconds))
        let available = trackEnd - start
        guard available > 0.01, clip.renderSourceDuration > 0.01 else { return nil }
        let sourceDuration = min(clip.renderSourceDuration, available)

        let originalPiece = Piece(track: original, offset: 0, covers: 0...max(trackEnd, start + sourceDuration))
        var pieces = proxyPieces(start: start, duration: sourceDuration, proxies: proxies) ?? [originalPiece]
        let isVideo = original.mediaType == .video

        // 只往合成轨真正的末尾后面接，不信 Double 游标（CompositionTime）。
        CompositionTime.pad(track, to: CompositionTime.tick(at))
        var position = at
        if holdHead > 0.0005 {
            if isVideo {
                let piece = piece(at: start, in: pieces) ?? originalPiece
                await CompositionHold.insert(
                    source: piece.track, frameAt: start - piece.offset, duration: holdHead, into: track, at: position
                )
            } else {
                CompositionTime.pad(track, to: CompositionTime.tick(position + holdHead))
            }
            position += holdHead
        }
        let insertAt = CompositionTime.appendPoint(CompositionTime.tick(position), on: track)
        let total = CompositionTime.tick(sourceDuration)
        if !append(pieces: pieces, start: start, total: total, into: track, at: insertAt) {
            // 代理的哪一片插不进去（块文件没了、范围对不上）：撤掉插了一半的，按原片再来一遍。
            guard pieces.count > 1 || pieces[0].track !== original else { return nil }
            if CompositionTime.end(of: track) > insertAt {
                track.removeTimeRange(CMTimeRange(start: insertAt, end: CompositionTime.end(of: track)))
            }
            pieces = [originalPiece]
            guard append(pieces: pieces, start: start, total: total, into: track, at: insertAt) else { return nil }
        }
        // 真素材那一段在时间线上的长度。被收口的部分按同一比例折算（= 取到的素材秒 ÷ 变速），画面和声音才不会错位。
        let realDuration = sourceDuration / max(0.05, clip.speed)
        if abs(clip.speed - 1) > 0.001 {
            track.scaleTimeRange(CMTimeRange(start: insertAt, duration: total), toDuration: CompositionTime.tick(realDuration))
        }
        position += realDuration
        if holdTail > 0.0005, isVideo {
            // 尾帧定格一直铺到这段的结尾：素材被收口短了一截时，差的那点也由定格补上，免得定格前面夹一条黑缝。
            let last = pieces.last ?? originalPiece
            let frame = await CompositionHold.frameDuration(of: last.track)
            let frameAt = max(start, start + sourceDuration - frame)
            let piece = piece(at: frameAt, in: pieces) ?? last
            await CompositionHold.insert(
                source: piece.track, frameAt: frameAt - piece.offset,
                duration: at + clip.timelineDuration - position, into: track, at: position
            )
        }
        cursor = at + clip.timelineDuration
        return pieces.first?.track ?? original
    }

    /// 这一截要用的代理块都在才给；没有代理、差一块都是 nil（插原片）。
    static func proxyPieces(start: Double, duration: Double, proxies: [Int: AVAssetTrack]?) -> [Piece]? {
        guard let proxies, !proxies.isEmpty else { return nil }
        var pieces: [Piece] = []
        for chunk in OptimizedMediaPolicy.coveringChunks(sourceStart: start, sourceDuration: duration, sourceLength: .infinity) {
            guard let track = proxies[chunk] else { return nil }
            let range = OptimizedMediaPolicy.chunkRange(chunk)
            pieces.append(Piece(track: track, offset: range.lowerBound, covers: range))
        }
        return pieces
    }

    /// 源时间 `seconds` 落在哪一片上。
    static func piece(at seconds: Double, in pieces: [Piece]) -> Piece? {
        pieces.first { $0.covers.contains(seconds) && seconds < $0.covers.upperBound } ?? pieces.last
    }

    /// 从源时间 `start` 起、共 `total` 格，按片首尾相接插到 `at`。格子全在 600 分之一秒上算：每片的长度是边界之差，
    /// 加起来正好 `total`（各片各自截断会少一两格、接缝上露一帧黑）。
    private static func append(pieces: [Piece], start: Double, total: CMTime, into track: AVMutableCompositionTrack, at: CMTime) -> Bool {
        let startTick = CompositionTime.tick(start)
        let endTick = startTick + total
        var sourceCursor = startTick
        var target = at
        for (index, piece) in pieces.enumerated() {
            let pieceEnd = index == pieces.count - 1 ? endTick : min(endTick, CompositionTime.tick(piece.covers.upperBound))
            let duration = pieceEnd - sourceCursor
            guard duration > .zero else { continue }
            let localStart = sourceCursor - CompositionTime.tick(piece.offset)
            do {
                try track.insertTimeRange(CMTimeRange(start: localStart, duration: duration), of: piece.track, at: target)
            } catch {
                return false
            }
            sourceCursor = pieceEnd
            target = target + duration
        }
        return sourceCursor == endTick
    }
}
