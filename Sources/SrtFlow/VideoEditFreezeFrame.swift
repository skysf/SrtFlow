import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - 定格（Freeze Frame）
//
// 把播放头下那一帧抽成 PNG，在播放头处切开原段，图片作为一段静止画面插进中间。
//
// **一行合成器代码都不用写**：抽出来的 PNG 走的是图片素材的老管线
// （`StillImageClipFactory` 转静帧循环视频 → 当普通剪辑用），所以定格段天生
// 支持转场、变速、画中画、关键帧、导出。
//
// 和图片导入的区别是**提交模型**：图片导入是「占位块先上轨、后台转完再替换」，
// 定格是**转码全部成功之后一次性提交**。原因见 `runFreeze` 的注释。

extension VideoEditProject {

    /// 工具栏按钮的置灰条件。
    var canFreezeFrame: Bool { !isFreezing && freezeTarget() != nil }

    /// 定格谁：选中且播放头落在里面的那一段，否则播放头下的主轨段。
    func freezeTarget() -> EditClip? {
        let time = clock.time
        let selected = selectedClipIDs
            .compactMap { state.clip(with: $0) }
            .filter { $0.contains(time: time) }
        // 选了好几段、播放头同时穿过不止一段：不猜是哪一段，直接不给定格。
        if selected.count > 1 { return nil }

        guard let clip = selected.first ?? mainClipAtPlayhead() else { return nil }
        guard isFreezeEligible(clip, at: time) else { return nil }
        return clip
    }

    /// 能不能对这一段在这个时刻定格。
    ///
    /// 入口要用，**提交前的 CAS 也要再跑一遍** —— 抽帧+转码那 1~2 秒里用户可能
    /// 给这一段加了转场、把它挪去画中画、或者把整条轨藏起来。
    func isFreezeEligible(_ clip: EditClip, at time: Double) -> Bool {
        // 纯音频没有画面；图片段本来就是静止的；还在转静帧的占位段连素材都没有。
        guard !clip.isAudioOnly, !clip.isStillImage, !clip.needsStillConversion else { return false }
        guard clip.contains(time: time) else { return false }
        guard let location = state.location(of: clip.id) else { return false }
        // 藏起来的轨在预览和导出里都当不存在，没有「这一帧」可言。
        guard !state.isLaneHidden(location.track) else { return false }
        guard location.track.isMain else { return true }
        // 主轨：牵扯转场的段一律不给定格（会让声画永久错开，理由见
        // `participatesInMainTransition`），叠化区里也不给（画面是合成的）。
        return !state.participatesInMainTransition(clipID: clip.id)
            && !state.isInsideMainTransition(time: time)
    }

    /// 工具栏 / ⇧⌘F 的入口。
    func freezeFrameAtPlayhead() {
        guard !isFreezing, let clip = freezeTarget() else { return }
        guard let ffmpeg = MediaToolchain.shared.runtime?.url else {
            notice = L10n("The video engine is not ready yet.")
            return
        }
        guard let track = state.location(of: clip.id)?.track else { return }
        let request = FreezeRequest(
            clip: clip,
            track: track,
            cutTime: clock.time,
            generation: documentGeneration
        )
        isFreezing = true
        trackImportTask(Task {
            defer { self.isFreezing = false }
            await self.runFreeze(request, ffmpeg: ffmpeg)
        })
    }

    /// 抽帧 → 写图 → 转码 → 探测 → **一次性提交**。
    ///
    /// 刻意**不**抄图片导入的占位流程，因为那条路在这里有三个问题：
    ///   1. 转码失败时它用**第二次** `perform` 把占位块删掉（见
    ///      `addImages` 的 catch），撤销栈上就留下两条记录 —— 用户按一次 ⌘Z
    ///      只撤回一半；
    ///   2. 占位块在预览里是被跳过的，中间会黑掉 1~2 秒；
    ///   3. 异步窗口里目标段可能被拖走/裁掉/改速，占位块已经插进去了没法回头。
    ///
    /// 全部成功 + CAS 通过才动时间线，于是定格段**创建即完整**，
    /// 撤销/重做严格一步，也不需要任何回滚合同。
    private func runFreeze(_ request: FreezeRequest, ffmpeg: URL) async {
        beginBackgroundImport()
        defer { endBackgroundImport() }

        guard let clip = state.clip(with: request.clipID) else { return }
        let sourceTime = clip.sourceTime(atTimeline: request.cutTime)
        // 半帧容差要用**源空间**的：源时间比时间线时间快 speed 倍。这个空间陷阱在
        // VideoEditAnimation.swift 里有详细注释。抽帧退路和下面的 drift 判定
        // 用的是同一把尺 —— drift 本身就是源时间，拿时间线半帧去比会在变速段上
        // 误报或漏报。
        let sourceHalfFrame = KeyframeTrack.sourceTolerance(
            frameRate: state.frameRate,
            speed: clip.speed
        )

        let frame: ExtractedFrame
        do {
            frame = try await Self.extractFrame(
                from: request.sourceURL,
                atSourceTime: sourceTime,
                tolerance: sourceHalfFrame
            )
        } catch {
            guard isCurrentGeneration(request.generation) else { return }
            notice = String(
                format: L10n("Could not read the frame at the playhead from %@."),
                clip.name
            )
            return
        }
        guard isCurrentGeneration(request.generation) else { return }

        let image: URL
        do {
            image = try writeFreezeImage(frame.image, clipName: clip.name, at: request.cutTime)
        } catch {
            guard isCurrentGeneration(request.generation) else { return }
            notice = error.localizedDescription
            return
        }

        // 提交不成功，这张 PNG 就还没有任何人引用 —— 别把垃圾留在用户的工程
        // 文件夹里。成功提交的那张要留着（重做要靠它）。
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: image) } }

        let still: URL
        do {
            still = try await StillImageClipFactory.stillVideo(
                for: image,
                ffmpeg: ffmpeg,
                // 只在**真的会被缩**的时候才走原生政策。尺寸没过照片上限时两条
                // 政策产出完全一样，统一走照片政策，好让这张图的政策能从
                // `info.displaySize` 唯一反推出来（缓存被清后要按原政策重转）。
                nativeResolution: StillImageClipFactory.needsNativeResolution(
                    for: CGSize(width: frame.image.width, height: frame.image.height)
                )
            )
        } catch {
            guard isCurrentGeneration(request.generation) else { return }
            notice = error.localizedDescription
            return
        }
        guard isCurrentGeneration(request.generation) else { return }
        guard let info = await probeVideo(still) else {
            guard isCurrentGeneration(request.generation) else { return }
            notice = String(
                format: L10n("Could not read video information from %@."),
                still.lastPathComponent
            )
            return
        }

        // CAS：抽帧+转码这 1~2 秒里，用户完全可能把目标段拖走、裁掉、改速度、
        // 加转场、挪去画中画、把整条轨藏起来。那样这一帧对应的时间线位置已经
        // 不成立了，整单作废比插错地方强。
        //
        // **准入条件要整个重跑一遍**（`isFreezeEligible`），不能只比源范围：
        // 从主轨挪到画中画会保持同样的起点和源范围却走完全不同的 ripple 语义；
        // 中途给这一段加转场则会让声画永久错开。
        guard isCurrentGeneration(request.generation),
              let current = state.clip(with: request.clipID),
              request.matches(current),
              state.location(of: request.clipID)?.track == request.track,
              isFreezeEligible(current, at: request.cutTime) else {
            guard isCurrentGeneration(request.generation) else { return }
            notice = L10n("The clip changed while the freeze frame was being prepared. Try again.")
            return
        }

        let isOverlay = !request.track.isMain
        let freeze = current.makeFreezeClip(
            image: image,
            still: still,
            info: info,
            at: request.cutTime,
            canvas: renderSize,
            isOverlay: isOverlay
        )
        perform { state in
            state.insertFreeze(freeze, splitting: request.clipID, at: request.cutTime)
        }
        // 「插进去了」以时间线里真有这一段为准，不能因为调过 perform 就当成功：
        // `insertFreeze` 自己也有前置条件，一旦它和上面的 CAS 判据出现分歧，
        // 无脑置 true 会既留下孤儿 PNG 又对用户报成功。
        committed = state.clip(with: freeze.id) != nil
        guard committed else {
            notice = L10n("The clip changed while the freeze frame was being prepared. Try again.")
            return
        }
        selectedClipIDs = [freeze.id]

        // VFR / 低帧率素材上「所见即所定」是尽力而为：真取到别的帧就说一声，
        // 别让用户对着差了半帧的画面找原因。drift 是**源时间**，所以拿源空间的
        // 半帧去比（变速段上两者差 speed 倍）。
        if abs(frame.drift) > sourceHalfFrame {
            notice = L10n("This clip has no frame exactly at the playhead, so the nearest one was used.")
        }
    }

    // MARK: - 抽帧

    private struct ExtractedFrame {
        var image: CGImage
        /// 实际取到的帧和请求时刻差多少秒（源时间）。VFR/低帧率素材上会不为 0。
        var drift: Double
    }

    private static func extractFrame(
        from url: URL,
        atSourceTime seconds: Double,
        tolerance: Double
    ) async throws -> ExtractedFrame {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        // 整条静帧管线是 SDR（yuv420p、无 HDR 元数据）。这里显式写死默认值，
        // 让 HDR 素材的色调映射至少是**可预期**的那一种，而不是跟着系统默认漂。
        generator.dynamicRangePolicy = .forceSDR
        let requested = CMTime(seconds: max(0, seconds), preferredTimescale: 600)

        func take() async throws -> ExtractedFrame {
            let result = try await generator.image(at: requested)
            return ExtractedFrame(
                image: result.image,
                drift: (result.actualTime - requested).seconds
            )
        }

        // 主路径零容差：定格要的就是「播放头上正显示的那一帧」。给了容差，
        // AVFoundation 可以在窗口内自由取（通常就近拿关键帧），定出来的画面
        // 和眼睛看到的对不上。
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        do {
            return try await take()
        } catch {
            // 索引损坏、异常 VFR 之类零容差会直接失败，退一步取最近的一帧。
            let window = CMTime(seconds: max(tolerance, 0.001), preferredTimescale: 600)
            generator.requestedTimeToleranceBefore = window
            generator.requestedTimeToleranceAfter = window
            return try await take()
        }
    }

    // MARK: - 写图

    /// 把定格帧写成 PNG，放在**工程文件旁边**；工程还没存过就放 Downloads。
    ///
    /// 刻意不放缓存目录：那里的东西随时会被系统清掉，而这张图是工程唯一的
    /// 事实来源（静帧 mp4 只是它的缓存产物）。清没了的话工程再打开会要求用户
    /// 重链接一张他从来没见过的图。
    private func writeFreezeImage(_ image: CGImage, clipName: String, at time: Double) throws -> URL {
        let folder = documentURL?.deletingLastPathComponent()
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser

        let base = "\(Self.sanitizedFileName(clipName))-freeze-\(Self.timecodeSlug(time))"
        var destination = folder.appendingPathComponent("\(base).png")
        var counter = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent("\(base)-\(counter).png")
            counter += 1
        }

        // 写盘失败的收尾要在**这里**做：调用方的清理 defer 要等这个方法返回 URL
        // 之后才建立得起来，半截文件在那之前就已经躺在用户的工程文件夹里了。
        let failure = FreezeFrameError(message: String(
            format: L10n("Could not save the freeze frame to %@."),
            folder.lastPathComponent
        ))
        guard let sink = CGImageDestinationCreateWithURL(
            destination as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            try? FileManager.default.removeItem(at: destination)
            throw failure
        }
        CGImageDestinationAddImage(sink, image, nil)
        guard CGImageDestinationFinalize(sink) else {
            try? FileManager.default.removeItem(at: destination)
            throw failure
        }
        return destination
    }

    /// `0m03s21` —— 定格点的时间线时刻，让文件名一眼能对上是哪一帧。
    private static func timecodeSlug(_ seconds: Double) -> String {
        let total = max(0, seconds)
        let whole = total.rounded(.down)
        return String(
            format: "%02dm%02ds%02d",
            Int(whole) / 60,
            Int(whole) % 60,
            Int(((total - whole) * 100).rounded(.down))
        )
    }

    private static func sanitizedFileName(_ name: String) -> String {
        var cleaned = name
        for bad in ["/", ":", "\\"] {
            cleaned = cleaned.replacingOccurrences(of: bad, with: "-")
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count > 60 { cleaned = String(cleaned.prefix(60)) }
        return cleaned.isEmpty ? "clip" : cleaned
    }
}

// MARK: - 入口时刻的目标快照

/// 抽帧、写图、转码要花 1~2 秒，这期间目标段完全可能被拖走、裁切、改速。
/// 提交前拿它逐字段核对（CAS），对不上就整单作废。
private struct FreezeRequest {
    var clipID: UUID
    /// 目标当时在哪条轨。**必须记**：主轨和画中画的 ripple 语义完全不同，
    /// 而挪轨可以保持起点和源范围不变，光比那些字段是发现不了的。
    var track: TrackSlot
    var sourceURL: URL
    var sourceStart: Double
    var sourceDuration: Double
    var speed: Double
    var timelineStart: Double
    var cutTime: Double
    var generation: Int

    init(clip: EditClip, track: TrackSlot, cutTime: Double, generation: Int) {
        clipID = clip.id
        self.track = track
        sourceURL = clip.sourceURL
        sourceStart = clip.sourceStart
        sourceDuration = clip.sourceDuration
        speed = clip.speed
        timelineStart = clip.timelineStart
        self.cutTime = cutTime
        self.generation = generation
    }

    /// 这一帧对应的时间线位置还成立吗。
    func matches(_ clip: EditClip) -> Bool {
        clip.sourceURL == sourceURL
            && abs(clip.sourceStart - sourceStart) < 0.0005
            && abs(clip.sourceDuration - sourceDuration) < 0.0005
            && abs(clip.speed - speed) < 0.0005
            && abs(clip.timelineStart - timelineStart) < 0.0005
    }
}

private struct FreezeFrameError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}
