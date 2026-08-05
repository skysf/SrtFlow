import AVFoundation
import Foundation

/// 导出全程（预渲染 + ffmpeg）共用的取消令牌。预渲染阶段没有 Process 可
/// terminate，Stop 只能靠它转发到当前正在跑的 AVAssetExportSession；
/// ffmpeg 阶段照旧走 FFmpegProcess.cancel()，两段各管各的。
final class ExportCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private weak var activeSession: AVAssetExportSession?

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let session = activeSession
        lock.unlock()
        session?.cancelExport()
    }

    /// 原子地「未取消才真正起跑」：`start` 必须是**同步启动导出**的调用
    /// （exportAsynchronously —— 它返回时导出已经开始），整个包在和
    /// cancel() 同一把锁里。这样 cancel() 拿到锁时只有两种世界：导出还没
    /// 起跑（cancelled 已置位，start 永远不会执行）、或已经起跑
    /// （cancelExport() 合法）。cancelExport() 只对已经起跑的会话安全——
    /// 对一条 .unknown 会话先 cancelExport() 再 export()，AVFoundation
    /// 内部断言直接崩进程（NSInternalInconsistencyException，Swift 的
    /// catch 拦不住）。之前「先登记、出临界区再启动」的写法在登记和启动
    /// 之间留了缝，cancel 恰好落进缝里就是同一个崩溃——启动必须发生在
    /// 临界区**内**，详见 docs/bugfixes/2026-08-05-export-prerender-review.md。
    fileprivate func startSession(_ session: AVAssetExportSession, start: () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        start()
        activeSession = session
        return true
    }

    /// 会话跑完（无论成功/失败/取消）后调用，清空登记，避免 cancel()
    /// 在会话已经结束后还去调一个过期引用的 cancelExport()。
    fileprivate func endSession() {
        lock.lock()
        activeSession = nil
        lock.unlock()
    }
}

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
/// - fill：内容本身（带完整不透明度）合在黑底上；
/// - matte：一块纯白素材套上**同一份**摆放/旋转/不透明度动画合在黑底上，
///   白 = 可见、黑 = 透明，边缘的抗锯齿灰阶就是 alpha 渐变。
/// 两条的权重必须一字不差（都是 coverage×opacity）：ffmpeg 里先用 matte
/// 把 fill 除回真实色再 `alphamerge` 合回带 alpha 的流，原位叠放——
/// 权重不一致除法就约不干净（细节见 VideoEditExporter 的画中画滤镜段）。
enum AnimatedClipPrerenderer {
    struct PrerenderError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// 主轨动画段 → 黑底 ProRes 422 中间片。
    static func renderMain(
        clip: EditClip,
        renderSize: CGSize,
        into workspace: URL,
        cancellation: ExportCancellationToken? = nil
    ) async throws -> URL {
        var state = TimelineState()
        state.mainClips = [normalized(clip)]
        return try await render(
            state: state,
            renderSize: renderSize,
            preset: AVAssetExportPresetAppleProRes422LPCM,
            output: workspace.appendingPathComponent("prerender-\(clip.id.uuidString).mov"),
            clipName: clip.name,
            cancellation: cancellation
        )
    }

    /// 画中画动画段 → (fill, matte) 两条黑底 ProRes 422 中间片。
    static func renderOverlay(
        clip: EditClip,
        renderSize: CGSize,
        into workspace: URL,
        cancellation: ExportCancellationToken? = nil
    ) async throws -> (fill: URL, matte: URL) {
        // 摆放基准固化成显式 placement：fill 和 matte 的默认布局必须一字不差
        //（matte 的白块素材尺寸和原素材不同，靠素材推默认布局会各说各话）。
        let basePlacement = clip.resolvedPlacement(canvas: renderSize, isOverlay: true)

        var fill = normalized(clip)
        fill.placement = basePlacement
        // fill 要保留完整不透明度（静态 + 动画），跟 matte 是同一份权重：
        // fill = 真实色×coverage×opacity，matte = coverage×opacity。ffmpeg
        // 那边靠 matte 把 fill 除回真实色（真实色=255×fill/matte），opacity
        // 这个因子必须在分子分母里都出现才能约掉——早先版本在这里把 fill
        // 的 opacity 清成 1（当时的 alphamerge 直接喂 straight overlay，
        // 保留 opacity 会导致边缘系数被压两次），现在换成先除后合的管线，
        // 这个理由已经不成立：fill 不带 opacity 会让除出来的颜色被放大
        // 1/opacity 倍，最终合成时不透明度被抵消掉一部分甚至全部。
        // 见 docs/bugfixes/2026-08-05-export-prerender-review.md。
        var fillState = TimelineState()
        fillState.overlayTracks = [EditLane(clips: [fill])]
        let fillURL = try await render(
            state: fillState,
            renderSize: renderSize,
            preset: AVAssetExportPresetAppleProRes422LPCM,
            output: workspace.appendingPathComponent("prerender-\(clip.id.uuidString)-fill.mov"),
            clipName: clip.name,
            cancellation: cancellation
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
            clipName: clip.name,
            cancellation: cancellation
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
        clipName: String,
        cancellation: ExportCancellationToken?
    ) async throws -> URL {
        if cancellation?.isCancelled == true { throw CancellationError() }
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
        // 启动和取消必须在同一临界区里互斥（见 startSession 注释）。这里
        // 特意用回调式 exportAsynchronously 而不是 async 的 export()：前者
        // 同步返回时导出已经真正开始，才放得进临界区；后者从「检查取消」
        // 到「实际起跑」之间隔着挂起点，那道缝永远关不上。deployment
        // target 是 macOS 14，15 起的弃用警告不会触发；将来换新 API 时
        // 必须保住「启动在临界区内」这个性质。
        let started = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let start = { session.exportAsynchronously { continuation.resume(returning: true) } }
            if let cancellation {
                if !cancellation.startSession(session, start: start) {
                    continuation.resume(returning: false)
                }
            } else {
                start()
            }
        }
        cancellation?.endSession()
        guard started else { throw CancellationError() }
        if session.status == .cancelled || cancellation?.isCancelled == true {
            try? FileManager.default.removeItem(at: output)
            throw CancellationError()
        }
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
