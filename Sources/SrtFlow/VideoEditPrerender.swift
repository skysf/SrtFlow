import AVFoundation
import Foundation

/// 带关键帧动画的段在导出前的预渲染。
///
/// 用和预览**完全同一套**合成代码（VideoEditCompositionBuilder）把这一段
/// 渲成中间片再交给 ffmpeg 图 —— 预览和导出按构造一致，同时绕开 ffmpeg
/// 没有干净的逐帧缩放/透明度插值这件事（流尺寸中途不能变、alpha 没原生
/// 插值）。中间片都不带声音：音频链照旧读原素材，动画不影响声音。
///
/// 主轨段：合在黑底上出一条 ProRes 422，xfade/concat 照常吃。
///
/// 画中画段：默认合成器的 `backgroundColor` **只支持不透明色**（alpha 被
/// 忽略，文档明说），透明背景根本出不来 —— 所以走 fill + matte 双渲染：
/// - fill：内容本身（不带不透明度）合在黑底上；
/// - matte：一块纯白素材套上**同一份**摆放/旋转/不透明度动画合在黑底上，
///   白 = 可见、黑 = 透明，边缘的抗锯齿灰阶就是 alpha 渐变。
/// ffmpeg 里 `alphamerge` 把两条合回带 alpha 的流，原位叠放。
enum AnimatedClipPrerenderer {
    struct PrerenderError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// 主轨动画段 → 黑底 ProRes 422 中间片。
    static func renderMain(clip: EditClip, renderSize: CGSize, into workspace: URL) async throws -> URL {
        var state = TimelineState()
        state.mainClips = [normalized(clip)]
        return try await render(
            state: state,
            renderSize: renderSize,
            preset: AVAssetExportPresetAppleProRes422LPCM,
            output: workspace.appendingPathComponent("prerender-\(clip.id.uuidString).mov"),
            clipName: clip.name
        )
    }

    /// 画中画动画段 → (fill, matte) 两条黑底 ProRes 422 中间片。
    static func renderOverlay(
        clip: EditClip,
        renderSize: CGSize,
        into workspace: URL
    ) async throws -> (fill: URL, matte: URL) {
        // 摆放基准固化成显式 placement：fill 和 matte 的默认布局必须一字不差
        //（matte 的白块素材尺寸和原素材不同，靠素材推默认布局会各说各话）。
        let basePlacement = clip.resolvedPlacement(canvas: renderSize, isOverlay: true)

        var fill = normalized(clip)
        fill.placement = basePlacement
        // 不透明度交给 matte 承载，fill 保持全亮，否则会被压暗两次。
        fill.opacity = 1
        if var animation = fill.animation {
            animation.opacity = KeyframeTrack()
            fill.animation = animation.isEmpty ? nil : animation
        }
        var fillState = TimelineState()
        fillState.overlayTracks = [EditLane(clips: [fill])]
        let fillURL = try await render(
            state: fillState,
            renderSize: renderSize,
            preset: AVAssetExportPresetAppleProRes422LPCM,
            output: workspace.appendingPathComponent("prerender-\(clip.id.uuidString)-fill.mov"),
            clipName: clip.name
        )

        guard let whiteURL = await BlackBaseVideoFactory.whiteVideoURL() else {
            throw PrerenderError(
                message: String(format: L10n("Could not prepare the animated clip %@ for export."), clip.name)
            )
        }
        let source = normalized(clip)
        var matte = source
        matte.sourceURL = whiteURL
        matte.stillImageURL = nil
        matte.needsStillConversion = false
        matte.crop = nil
        matte.flippedHorizontally = false
        matte.flippedVertically = false
        matte.info = nil
        matte.placement = basePlacement
        // 白块素材只有 1 秒：从 0 取满 1 秒，用变速拉伸到段长（纯色无所谓帧率）。
        matte.sourceStart = 0
        matte.sourceDuration = 1
        matte.speed = 1 / max(source.timelineDuration, 0.05)
        // 关键帧锚在源时间上，而 matte 的源时间轴和原素材不同 ——
        // 把每个关键帧经由时间线时刻换算到 matte 自己的源轴上。
        matte.animation = remappedAnimation(from: source, to: matte)
        var matteState = TimelineState()
        matteState.overlayTracks = [EditLane(clips: [matte])]
        let matteURL = try await render(
            state: matteState,
            renderSize: renderSize,
            preset: AVAssetExportPresetAppleProRes422LPCM,
            output: workspace.appendingPathComponent("prerender-\(clip.id.uuidString)-matte.mov"),
            clipName: clip.name
        )
        return (fillURL, matteURL)
    }

    // MARK: - 内部

    /// 规范化到 0 起点。动画锚在源时间上，平移时间线起点不影响取值。
    private static func normalized(_ clip: EditClip) -> EditClip {
        var normalized = clip
        normalized.timelineStart = 0
        normalized.transitionAfter = .none
        normalized.isMuted = true
        return normalized
    }

    /// 把关键帧从原素材的源时间轴换算到另一段（不同 sourceStart/speed）的源轴。
    private static func remappedAnimation(from source: EditClip, to target: EditClip) -> ClipAnimation? {
        guard let animation = source.animation else { return nil }
        func convert(_ track: KeyframeTrack) -> KeyframeTrack {
            KeyframeTrack(keys: track.keys.map { key in
                Keyframe(
                    time: target.sourceTime(atTimeline: source.timelineTime(atSource: key.time)),
                    value: key.value
                )
            })
        }
        return ClipAnimation(
            centerX: convert(animation.centerX),
            centerY: convert(animation.centerY),
            width: convert(animation.width),
            height: convert(animation.height),
            rotation: convert(animation.rotation),
            opacity: convert(animation.opacity)
        )
    }

    private static func render(
        state: TimelineState,
        renderSize: CGSize,
        preset: String,
        output: URL,
        clipName: String
    ) async throws -> URL {
        guard let built = await VideoEditCompositionBuilder.build(
            from: state,
            renderSizeOverride: renderSize
        ), let session = AVAssetExportSession(asset: built.composition, presetName: preset) else {
            throw PrerenderError(
                message: String(format: L10n("Could not prepare the animated clip %@ for export."), clipName)
            )
        }
        session.videoComposition = built.videoComposition
        try? FileManager.default.removeItem(at: output)
        session.outputURL = output
        session.outputFileType = .mov
        await session.export()
        guard session.status == .completed, FileManager.default.fileExists(atPath: output.path) else {
            try? FileManager.default.removeItem(at: output)
            throw PrerenderError(message: String(
                format: L10n("Could not prepare the animated clip %@ for export."),
                clipName
            ) + " " + (session.error?.localizedDescription ?? ""))
        }
        return output
    }
}
