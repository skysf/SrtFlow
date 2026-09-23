import AVFoundation
import CoreVideo
import Foundation
import SrtFlowCore

/// 预览合成的纯色底素材：64×36 的两帧纯色 H.264，AVAssetWriter 直接生成，
/// 不依赖 ffmpeg。黑底垫在半透明合成下面；白底给上层轨关键帧段的蒙版
/// 预渲染当「白块」用。放在缓存目录，被系统清掉就重新写一个。
///
/// actor + 单飞：预览重建高频触发，并发进来只允许一个真正去写；生成先落
/// **唯一命名的临时文件**，写完验证能读出视频轨才原子替换到正式路径 ——
/// 光看「文件存在」会把并发写到一半的残骸当缓存，绿底就回来了。
actor BlackBaseVideoFactory {
    static let shared = BlackBaseVideoFactory()

    private var inFlight: [String: Task<URL?, Never>] = [:]

    static func videoURL() async -> URL? {
        await shared.resolve(fileName: "black-base-v1.mp4", bgra: 0xFF00_0000)
    }

    /// 纯白版本（蒙版渲染的「白块」素材）。
    static func whiteVideoURL() async -> URL? {
        await shared.resolve(fileName: "white-base-v1.mp4", bgra: 0xFFFF_FFFF)
    }

    private func resolve(fileName: String, bgra: UInt32) async -> URL? {
        let destination = Self.cacheURL(fileName)
        if await Self.isUsable(destination) { return destination }
        if let existing = inFlight[fileName] { return await existing.value }
        let task = Task { await Self.generate(to: destination, bgra: bgra) }
        inFlight[fileName] = task
        let result = await task.value
        inFlight[fileName] = nil
        return result
    }

    private static func cacheURL(_ fileName: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SrtFlowPreview", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    /// 真能当素材用吗：必须读得出视频轨且时长正常，坏文件当场删掉重来。
    private static func isUsable(_ url: URL) async -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let range = try? await track.load(.timeRange),
              range.duration.seconds > 0.5 else {
            try? FileManager.default.removeItem(at: url)
            return false
        }
        return true
    }

    private static func generate(to destination: URL, bgra: UInt32) async -> URL? {
        let directory = destination.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temp = directory.appendingPathComponent("base-\(UUID().uuidString).tmp.mp4")
        // 所有提前退出的分支都不许留半成品。
        defer { try? FileManager.default.removeItem(at: temp) }

        do {
            let writer = try AVAssetWriter(outputURL: temp, fileType: .mp4)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 64,
                AVVideoHeightKey: 36
            ])
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: 64,
                    kCVPixelBufferHeightKey as String: 36
                ]
            )
            writer.add(input)
            guard writer.startWriting() else { return nil }
            writer.startSession(atSourceTime: .zero)

            guard let pool = adaptor.pixelBufferPool else { return nil }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { return nil }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let baseAddress = CVPixelBufferGetBaseAddress(buffer) {
                let byteCount = CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer)
                // 按 32 位 BGRA 模式填纯色（A=255 的黑或白）。
                let words = baseAddress.assumingMemoryBound(to: UInt32.self)
                for index in 0..<(byteCount / 4) { words[index] = bgra }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])

            // isReadyForMoreMediaData 在 writer 异步失败后可能**永远**不恢复
            // （Apple 文档明说会长时间为 false）。不设状态检查和超时的话，
            // 这个循环挂死 → 单飞任务永不返回 → 之后所有预览重建全部卡在它上。
            var waitedNanoseconds: UInt64 = 0
            for seconds in [0.0, 1.0] {
                while !input.isReadyForMoreMediaData {
                    guard writer.status == .writing, waitedNanoseconds < 5_000_000_000 else {
                        writer.cancelWriting()
                        return nil
                    }
                    try? await Task.sleep(nanoseconds: 5_000_000)
                    waitedNanoseconds += 5_000_000
                }
                // append 返回 false 就是写失败（Apple 文档明说），不能当没看见。
                guard adaptor.append(
                    buffer,
                    withPresentationTime: CMTime(seconds: seconds, preferredTimescale: 600)
                ) else {
                    writer.cancelWriting()
                    return nil
                }
            }
            input.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else { return nil }

            // 原子替换到正式路径，最后再验一遍才交出去。
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: destination)
            }
            guard await isUsable(destination) else { return nil }
            return destination
        } catch {
            return nil
        }
    }
}

/// 把时间线状态翻译成 AVFoundation 的预览合成。
///
/// 结构：主轨用**两条**合成视频轨 A/B 交替放段落 —— 转场要求前后两段在重叠区
/// 同时有画面，同一条轨做不到。上层视频轨每条时间线轨各占一条合成轨。转场用
/// 透明度渐变近似（压黑/闪白在导出时由 xfade 精确渲染，预览的时间账完全一致）。
/// 变速用 scaleTimeRange，播放条目上配 `.spectral` 保音调，跟导出的 atempo 听感一致。
enum VideoEditCompositionBuilder {

    struct Built {
        var composition: AVMutableComposition
        var videoComposition: AVMutableVideoComposition?
        var audioMix: AVMutableAudioMix?
        /// 「谁的声音在哪条合成音轨上」。留着它，改音量/渐变时就能只换 mix、
        /// 不重建合成（见 `makeAudioMix`）。
        var audioPlan: AudioMixPlan
        var renderSize: CGSize
    }

    /// 素材摆进画布所需的固定几何量（关键帧动画每片重算变换时复用）。
    private struct ClipGeometry {
        var preferredTransform: CGAffineTransform
        /// 源旋转摆正后包围盒的原点（挪回原点用）。
        var boundsOrigin: CGPoint
        /// 显示方向上的裁切区（没裁就是整幅）。
        var sourceRect: CGRect
    }

    /// 预览里参与画面合成的一段（换算好合成轨和转场之后的产物）。
    private struct PlacedClip {
        var clip: EditClip
        /// 这段落在哪条合成轨上。layer instruction 要拿它当 assetTrack 用。
        var track: AVMutableCompositionTrack
        var transform: CGAffineTransform
        /// 四边裁切换算回源轨自然坐标系的矩形；nil = 不裁。
        var cropRect: CGRect?
        /// 关键帧动画的段每片重算变换用；静态段是 nil。
        var geometry: ClipGeometry?
        /// 画面的叠放层级，越大越靠上（主轨 0，上层视频轨 1+轨号）。
        var layer: Int
        var start: Double { clip.timelineStart }
        var end: Double { clip.timelineEnd }
        /// 开头的淡入（跟上一段的转场决定），(时长, 后半才亮?)。
        var fadeIn: (duration: Double, delayedHalf: Bool)?
        /// 结尾的淡出，(时长, 前半就灭?)。
        var fadeOut: (duration: Double, earlyHalf: Bool)?
        /// 推移转场：开头从这个画布偏移（像素）线性滑回原位。
        var pushIn: (duration: Double, fromDX: CGFloat, fromDY: CGFloat)?
        /// 推移转场：结尾从原位线性滑出到这个画布偏移。
        var pushOut: (duration: Double, toDX: CGFloat, toDY: CGFloat)?
        /// 擦除转场（只挂出场段）：结尾的可见画布窗口按方向线性缩小，
        /// 露出来的就是垫在下面的进场段。
        var wipeOut: (duration: Double, kind: ClipTransition)?
        /// 预设的入/出场动画（已做过转场仲裁）。`.none` = 这一段不走逐帧那条路。
        ///
        /// **它和上面的 `fadeIn/fadeOut` 互斥**：效果是纯 `.fade` 时照旧走
        /// 透明度斜坡（预览/导出都不必逐帧），只有要逐帧的效果才落到这里，
        /// 那时用户的头尾渐变整个由它自己的曲线负责 —— 两条路同时开会把
        /// 透明度乘两遍。挂在这儿的仲裁结果见 `ClipPreset.effective`。
        var preset: ResolvedClipPreset = .none
    }

    /// - Parameter renderSizeOverride: 导出预渲染要用外层时间线的画布尺寸，
    ///   传它覆盖「按素材推断」的默认逻辑。
    ///
    /// 注意：默认合成器的 `backgroundColor` **只支持不透明色（alpha 被忽略，
    /// 文档明说）**，所以这里出不了透明背景 —— 带 alpha 的预渲染走
    /// fill + matte 双渲染（见 AnimatedClipPrerenderer）。
    static func build(
        from state: TimelineState,
        renderSizeOverride: CGSize? = nil
    ) async -> Built? {
        // 主轨按数组顺序进 A/B 轨，插入游标只会前进：乱序的输入会让
        // `insertTimeRange` 把已插好的段往后挤（黑屏/画面错时）。状态侧的
        // 改动入口已维持有序，这里再守一道 —— 上层视频轨（下面）同款 sorted。
        var state = state
        state.sortMainClipsByStart()
        // 转场靠向两边借余料做出来，展开之后两段真的相叠 —— 下面那套按「相叠」
        // 写的淡变逻辑才成立。**导出图在同一个位置调同一个函数**，两条管线看到
        // 的是同一份时间线（VideoEditTransitionHandles.swift）。
        state = state.expandingTransitionHandles()
        guard !state.isEmpty else { return nil }

        let composition = AVMutableComposition()
        var placed: [PlacedClip] = []

        // 输出尺寸：第一段主轨素材说了算（预渲染时由外层画布指定）。
        let renderSize = renderSizeOverride ?? Self.renderSize(for: state)

        // 素材缓存：同一个文件出现几段，AVURLAsset 只开一次。
        var assets: [URL: AVURLAsset] = [:]
        func asset(for url: URL) -> AVURLAsset {
            if let existing = assets[url] { return existing }
            let created = AVURLAsset(url: url)
            assets[url] = created
            return created
        }

        // MARK: 主轨（A/B 交替）

        let videoA = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        let videoB = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        let audioA = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        let audioB = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        var videoCursors: [Double] = [0, 0]
        var audioCursors: [Double] = [0, 0]
        // 音量斜坡不在这儿铺：这一趟只记「谁的声音进了哪条合成音轨」，
        // 铺斜坡统一交给 `makeAudioMix` —— 它同时也是「只改音量/渐变时不重建
        // 合成、只换 audioMix」那条快路径的实现，两条路共用一份才不会分叉。
        var audioPlan = AudioMixPlan()
        // 主轨 clip 序号 → placed 序号（接缝后处理用；被跳过的段不在里面）。
        var placedIndexByMainIndex: [Int: Int] = [:]

        for (index, clip) in state.mainClips.enumerated() {
            // 整轨隐藏 → 主轨完全不进合成（预览是黑场）；单独隐藏的段（V）同理
            // —— 两级隐藏的渲染语义是同一条，画面和声音都不进（见
            // docs/architecture/clip-visibility.md）。
            // 还在后台转静帧的图片占位块也先跳过，转完会重建。
            guard !state.mainHidden, !clip.isHidden, !clip.needsStillConversion else { continue }
            let slot = index % 2
            guard let videoTrack = (slot == 0 ? videoA : videoB) else { continue }
            let sourceAsset = asset(for: clip.sourceURL)
            guard let sourceVideo = try? await sourceAsset.loadTracks(withMediaType: .video).first else { continue }

            guard await insert(
                source: sourceVideo,
                clip: clip,
                into: videoTrack,
                cursor: &videoCursors[slot]
            ) else { continue }

            let naturalSize = (try? await sourceVideo.load(.naturalSize)) ?? renderSize
            let preferred = (try? await sourceVideo.load(.preferredTransform)) ?? .identity
            let fitted = fittingTransform(
                naturalSize: naturalSize,
                preferredTransform: preferred,
                renderSize: renderSize,
                clip: clip)

            // 接缝的转场分派放到主轨循环之后统一做（推移/擦除的精确路径要看
            // 接缝两侧换算好的变换，处理到前一段时后一段的还没算出来）。
            placedIndexByMainIndex[index] = placed.count
            placed.append(PlacedClip(
                clip: clip,
                track: videoTrack,
                transform: fitted.transform,
                cropRect: fitted.cropRect,
                geometry: fitted.geometry,
                layer: 0
            ))

            // 声音
            if clip.hasAudio, !clip.isMuted,
               let audioTrack = (slot == 0 ? audioA : audioB),
               let sourceAudio = try? await sourceAsset.loadTracks(withMediaType: .audio).first,
               await insert(source: sourceAudio, clip: clip, into: audioTrack, cursor: &audioCursors[slot]) {
                audioPlan.record(trackID: audioTrack.trackID, clipID: clip.id, isMainTrack: true)
            }
        }

        // MARK: 主轨接缝的转场分派
        //
        // 三族三条路（详见 docs/architecture/preview-free-transform.md）：
        //
        // - 淡变族（叠化/压黑/闪白）：叠化在接缝两侧都「盖满画布且不透明」时走
        //   「后段垫底、前段淡出」，逐像素等于导出的 xfade dissolve；只要有一侧
        //   盖不满或半透明（缩小挪位、旋转透明角、整层透明度），「垫底常亮」会让
        //   后段从转场第一帧就透出来，而导出是先把每段压平到黑底再 dissolve ——
        //   这种接缝改成双向线性淡变（代价是中点轻微变暗）。判定必须用
        //   coversCanvasOpaquely，别拿 hasVisualTransform 凑：仅翻转照样满幅
        //   不透明，误走近似路径就是白闪变暗。压黑/闪白走半程模型（前半灭后半亮）。
        // - 推移族：两侧都轴对齐且非动画段 → 平移斜坡 + 「压平时的画布」裁切，
        //   逐像素等于「压平到黑底再整幅滑动」（缩放/翻转/半透明/盖不满都不破坏
        //   等价性，黑底垫着）；否则回退双向淡变。
        // - 擦除族：出场段满幅不透明且轴对齐 → 给出场段挂线性缩小的裁切窗口，
        //   露出来的就是垫底的进场段（进场段无任何前提：它差一块的地方露黑底，
        //   和导出压平模型一致）；否则回退双向淡变。
        // stride 而不是 1..<count：上层轨预渲染的状态主轨是空的，1..<0 直接崩。
        for index in stride(from: 1, to: state.mainClips.count, by: 1) {
            let kind = state.mainClips[index - 1].transitionAfter
            let overlap = state.transitionOverlap(afterMainIndex: index - 1)
            guard kind != .none, overlap > 0 else { continue }
            // 任一侧被单独隐藏 → 这条接缝不存在。隐藏的那段没有 placed 条目，
            // 不拦的话只有活着的那一侧挂上淡变 = 预览里它淡进黑场，而导出那边
            // 转场要求两段真的首尾相叠、隐藏的段早被滤掉 = 硬切。两边必须同解。
            guard !state.mainClips[index - 1].isHidden, !state.mainClips[index].isHidden
            else { continue }
            let outgoingIndex = placedIndexByMainIndex[index - 1]
            let incomingIndex = placedIndexByMainIndex[index]

            // 推移/擦除条件不满足时的回退：按叠化近似路径处理这条接缝。
            func fallBackToFade() {
                let halved = kind == .blackFade || kind == .whiteFade
                if let outgoingIndex { placed[outgoingIndex].fadeOut = (overlap, halved) }
                if let incomingIndex { placed[incomingIndex].fadeIn = (overlap, halved) }
            }

            switch kind.family {
            case .fade:
                let halved = kind != .crossFade
                let exactUnderlay = kind == .crossFade
                    && state.mainClips[index - 1].coversCanvasOpaquely(canvas: renderSize)
                    && state.mainClips[index].coversCanvasOpaquely(canvas: renderSize)
                if let outgoingIndex { placed[outgoingIndex].fadeOut = (overlap, halved) }
                if let incomingIndex, !exactUnderlay {
                    placed[incomingIndex].fadeIn = (overlap, halved)
                }
            case .push:
                guard let outgoingIndex, let incomingIndex, let motion = kind.motion,
                      pushSideExact(state.mainClips[index - 1], placed[outgoingIndex].transform),
                      pushSideExact(state.mainClips[index], placed[incomingIndex].transform)
                else {
                    fallBackToFade()
                    break
                }
                placed[outgoingIndex].pushOut = (
                    overlap, motion.dx * renderSize.width, motion.dy * renderSize.height
                )
                placed[incomingIndex].pushIn = (
                    overlap, -motion.dx * renderSize.width, -motion.dy * renderSize.height
                )
                // 压平模型里滑出画布的内容不会被滑回来看见：把两段都裁到
                // 「静止时的画布」（源坐标），滑动时裁切随内容一起走。
                clampCropToCanvas(&placed[outgoingIndex], renderSize: renderSize)
                clampCropToCanvas(&placed[incomingIndex], renderSize: renderSize)
            case .wipe:
                guard let outgoingIndex, incomingIndex != nil,
                      state.mainClips[index - 1].coversCanvasOpaquely(canvas: renderSize),
                      isAxisAlignedInvertible(placed[outgoingIndex].transform)
                else {
                    fallBackToFade()
                    break
                }
                placed[outgoingIndex].wipeOut = (overlap, kind)
            }
        }

        // MARK: 上层视频轨

        for (trackIndex, lane) in state.overlayTracks.enumerated()
        where !lane.clips.isEmpty && !lane.isHidden {
            guard let videoTrack = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { continue }
            let audioTrack = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
            )
            var videoCursor = 0.0
            var audioCursor = 0.0

            for clip in ClipVisibility.visible(lane.clips)
                .sorted(by: { $0.timelineStart < $1.timelineStart })
            where !clip.needsStillConversion {
                let sourceAsset = asset(for: clip.sourceURL)
                guard let sourceVideo = try? await sourceAsset.loadTracks(withMediaType: .video).first else { continue }
                guard await insert(source: sourceVideo, clip: clip, into: videoTrack, cursor: &videoCursor) else { continue }

                let naturalSize = (try? await sourceVideo.load(.naturalSize)) ?? renderSize
                let preferred = (try? await sourceVideo.load(.preferredTransform)) ?? .identity
                let fitted = fittingTransform(
                    naturalSize: naturalSize,
                    preferredTransform: preferred,
                    renderSize: renderSize,
                    clip: clip)
                placed.append(PlacedClip(
                    clip: clip,
                    track: videoTrack,
                    transform: fitted.transform,
                    cropRect: fitted.cropRect,
                    geometry: fitted.geometry,
                    layer: 1 + trackIndex
                ))

                if clip.hasAudio, !clip.isMuted,
                   let audioTrack,
                   let sourceAudio = try? await sourceAsset.loadTracks(withMediaType: .audio).first,
                   await insert(source: sourceAudio, clip: clip, into: audioTrack, cursor: &audioCursor) {
                    audioPlan.record(trackID: audioTrack.trackID, clipID: clip.id, isMainTrack: false)
                }
            }
        }

        // MARK: 音频轨

        for lane in state.audioTracks where !lane.clips.isEmpty && !lane.isHidden {
            guard let audioTrack = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { continue }
            var cursor = 0.0
            for clip in ClipVisibility.visible(lane.clips)
                .sorted(by: { $0.timelineStart < $1.timelineStart }) {
                let sourceAsset = asset(for: clip.sourceURL)
                guard let sourceAudio = try? await sourceAsset.loadTracks(withMediaType: .audio).first else { continue }
                guard await insert(source: sourceAudio, clip: clip, into: audioTrack, cursor: &cursor) else { continue }
                audioPlan.record(trackID: audioTrack.trackID, clipID: clip.id, isMainTrack: false)
            }
        }

        // MARK: 单段画面渐变
        //
        // 转场已经在上面的接缝分派里占好了它那条边（淡变族挂 fadeIn/fadeOut，
        // 推移族挂 pushIn/pushOut，擦除族挂 wipeOut）。这里补的是**用户给单段
        // 设的**渐变，所以有转场的一边一律让位 —— 判据与声音同源
        // （`FadeWindow.suppressing`），叠加会在接缝处把画面压暗一块。
        //
        // 渐变露出来的是这一段底下那层：主轨的底下是黑底轨，上层视频轨的底下
        // 是主轨画面。同一条斜坡、两种观感，导出侧靠 `fade=…:alpha=1` 对齐。
        for index in placed.indices {
            let clip = placed[index].clip
            let mainIndex = state.mainClips.firstIndex { $0.id == clip.id }
            let hasTransitionBefore = mainIndex.map {
                $0 > 0 && state.transitionOverlap(afterMainIndex: $0 - 1) > 0
            } ?? false
            // 上层视频轨目前没有轨内转场，那条边永远归用户的渐变管。
            let hasTransitionAfter = mainIndex.map {
                state.transitionOverlap(afterMainIndex: $0) > 0
            } ?? false
            // 入/出场动画与画面渐变是同一个槽（时长共用 `videoFade*`）：
            // 要逐帧的效果整条交给 `preset`（它自己的曲线里就含淡变），
            // 纯 `.fade`/没设效果的照旧走这里的透明度斜坡 —— 两条路互斥，
            // 同时开会把透明度乘两遍。
            let preset = ClipPreset.effective(
                clip: clip,
                hasTransitionBefore: hasTransitionBefore,
                hasTransitionAfter: hasTransitionAfter
            )
            if preset.needsPerFrameRender {
                placed[index].preset = preset
                continue
            }
            let window = VideoFade.effective(
                clip: clip,
                hasTransitionBefore: hasTransitionBefore,
                hasTransitionAfter: hasTransitionAfter
            )
            if window.fadeIn > 0, placed[index].fadeIn == nil {
                placed[index].fadeIn = (window.fadeIn, false)
            }
            if window.fadeOut > 0, placed[index].fadeOut == nil {
                placed[index].fadeOut = (window.fadeOut, false)
            }
        }

        // MARK: 不透明黑底轨
        //
        // 默认合成器的坑：画面上有半透明图层（Transform 的不透明度、转场的
        // 淡入淡出）时，它换到混合路径，`instruction.backgroundColor` 不再生效，
        // 未覆盖区域是零填充的 YUV 缓冲 —— 显示成暗绿色。所以这种时候垫一条
        // 真正的黑视频铺满全程当底，混合永远发生在不透明底之上。
        // 推移/擦除也要黑底：滑走/擦掉后露出来的未覆盖区必须是黑，
        // 而且裁切过的图层照样会把合成器切到混合路径。
        let needsOpaqueBase = placed.contains {
            $0.clip.minimumOpacity < 0.999 || $0.fadeIn != nil || $0.fadeOut != nil
                || $0.pushIn != nil || $0.pushOut != nil || $0.wipeOut != nil
                // 预设入/出场：头尾要么半透明、要么带裁切，两样都会把默认合成器
                // 切到混合路径（未覆盖区变暗绿色），必须垫黑底。
                || !$0.preset.isEmpty
        }
        if needsOpaqueBase, let baseURL = await BlackBaseVideoFactory.videoURL() {
            let baseAsset = asset(for: baseURL)
            if let baseSource = try? await baseAsset.loadTracks(withMediaType: .video).first,
               let baseTrack = composition.addMutableTrack(
                   withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
               ),
               let sourceRange = try? await baseSource.load(.timeRange),
               (try? baseTrack.insertTimeRange(sourceRange, of: baseSource, at: .zero)) != nil {
                baseTrack.scaleTimeRange(
                    CMTimeRange(start: .zero, duration: sourceRange.duration),
                    toDuration: time(state.duration)
                )
                let natural = (try? await baseSource.load(.naturalSize)) ?? CGSize(width: 64, height: 36)
                var base = EditClip(sourceURL: baseURL, sourceDuration: state.duration)
                base.timelineStart = 0
                placed.append(PlacedClip(
                    clip: base,
                    track: baseTrack,
                    transform: CGAffineTransform(
                        scaleX: renderSize.width / max(natural.width, 1),
                        y: renderSize.height / max(natural.height, 1)
                    ),
                    cropRect: nil,
                    geometry: nil,
                    layer: Int.min
                ))
            }
        }

        // 清掉没有任何内容的合成轨（A/B 双轨和音轨是无条件建的）。
        // AVPlayer 容忍空轨，AVAssetExportSession 会报 InvalidVideoComposition
        //（表述是 "Operation Stopped"）—— 预渲染走导出会话，必须干净。
        for track in composition.tracks where track.segments.isEmpty {
            composition.removeTrack(track)
        }
        let remainingTrackIDs = Set(composition.tracks.map(\.trackID))
        audioPlan.lanes.removeAll { !remainingTrackIDs.contains($0.trackID) }

        // 纯音频时间线：没有任何画面就不配 videoComposition。
        let hasVideoContent = placed.contains { !$0.clip.isAudioOnly }
        var videoComposition: AVMutableVideoComposition?
        if hasVideoContent {
            videoComposition = buildVideoComposition(
                placed: placed,
                renderSize: renderSize,
                totalDuration: state.duration,
                frameRate: state.frameRate
            )
        }

        return Built(
            composition: composition,
            videoComposition: videoComposition,
            audioMix: makeAudioMix(state: state, plan: audioPlan),
            audioPlan: audioPlan,
            renderSize: renderSize
        )
    }

    /// 按 `plan` 给每条合成音轨铺音量斜坡，产出 audioMix。
    ///
    /// 两个调用方共用它：`build()` 建完合成之后调一次；只改了音量/渐变时
    /// `VideoEditProject.refreshAudioMix()` 直接调它换掉正在播的 item 上的
    /// mix（**不重建合成，画面不闪**）。两条路必须是同一份实现 —— 分开写
    /// 就会出现「拖完滑块的音量」和「重建之后的音量」不一样。
    static func makeAudioMix(state: TimelineState, plan: AudioMixPlan) -> AVMutableAudioMix? {
        guard !plan.lanes.isEmpty else { return nil }
        var parameters: [AVMutableAudioMixInputParameters] = []
        for lane in plan.lanes {
            let params = AVMutableAudioMixInputParameters()
            params.trackID = lane.trackID
            // 同一条合成轨上，上一段的结束点就是插入游标当时的值。
            var previousEnd = 0.0
            for clipID in lane.clipIDs {
                guard let clip = state.clip(with: clipID) else { continue }
                // 轨道推子 × 总推子：两个都是常数，直接乘进这一段的每个设定点
                //（导出那边乘进同一段的 `volume=`，两条管线同一笔账，见
                // docs/architecture/audio-mixer.md）。
                let gainScale = state.trackVolume(containingClip: clipID) * state.masterVolume
                // 静音段不单独开分支：`addVolumeRamps` 里的音量已经是
                // `isMuted ? 0 : volume`，走同一条路才能同样享受「提前钉音量」——
                // 以前静音段是 `setVolume(0, at: 段起点)`，钉在起点上等于把
                // 1.0 → 0 的跳变留在段内，静音段的开头照样会漏出一下声音。
                // （主轨和上层轨的静音段压根不进合成，能走到这儿的只有音频轨。）
                if lane.isMainTrack, let index = state.mainClips.firstIndex(where: { $0.id == clipID }) {
                    addVolumeRamps(
                        params: params,
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
                        params: params, clip: clip, fades: clip.audioFades, previousEnd: previousEnd,
                        gainScale: gainScale
                    )
                }
                previousEnd = clip.timelineEnd
            }
            parameters.append(params)
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        return mix
    }

    // MARK: - 小工具

    private static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: max(0, seconds), preferredTimescale: 600)
    }

    static func renderSize(for state: TimelineState) -> CGSize {
        // 选了固定比例就用标准尺寸；auto 跟随第一段素材。
        if let fixed = state.canvasRatio.fixedSize { return fixed }
        let size = state.mainClips.compactMap(\.info).first?.displaySize
            ?? state.overlayTracks.flatMap(\.clips).compactMap(\.info).first?.displaySize
            ?? CGSize(width: 1920, height: 1080)
        // yuv420 的世界里宽高都得是偶数。
        return CGSize(
            width: max(2, (size.width / 2).rounded() * 2),
            height: max(2, (size.height / 2).rounded() * 2)
        )
    }

    /// 把素材段插进合成轨。轨内必须连续，落点之前的空档用空段补齐。
    /// 变速在插完之后用 scaleTimeRange 拉伸。
    ///
    /// 截取范围要收口到**源轨自己的范围**里：音频流经常比视频流短一小截，
    /// 按视频时长去截音频会越界抛错 —— 整段声音就这么无声无息地丢了。
    ///
    /// **首尾定格**（`renderHoldHead` / `renderHoldTail`，只有渲染副本里转场余料
    /// 不够的主轨段才有）：画面把首帧 / 尾帧插进来再拉长成定格，声音那一截留空。
    /// 导出那边是 `tpad` 复制首尾帧 + 补静音，同一笔账（VideoEditExportGraph）。
    private static func insert(
        source: AVAssetTrack,
        clip: EditClip,
        into track: AVMutableCompositionTrack,
        cursor: inout Double
    ) async -> Bool {
        let at = clip.timelineStart
        let holdHead = clip.renderHoldHead
        let holdTail = clip.renderHoldTail

        let trackRange = (try? await source.load(.timeRange))
            ?? CMTimeRange(start: .zero, duration: CMTime(seconds: clip.assetDuration, preferredTimescale: 600))
        let trackEnd = trackRange.end.seconds
        let start = max(clip.renderSourceStart, max(0, trackRange.start.seconds))
        let available = trackEnd - start
        guard available > 0.01, clip.renderSourceDuration > 0.01 else { return false }
        let sourceDuration = min(clip.renderSourceDuration, available)

        if at > cursor + 0.0005 {
            track.insertEmptyTimeRange(CMTimeRange(start: time(cursor), end: time(at)))
        }
        let isVideo = source.mediaType == .video
        var position = at
        if holdHead > 0.0005 {
            if isVideo {
                await insertHold(
                    source: source, frameAt: start, duration: holdHead, into: track, at: position
                )
            } else {
                track.insertEmptyTimeRange(
                    CMTimeRange(start: time(position), duration: CMTime(seconds: holdHead, preferredTimescale: 600))
                )
            }
            position += holdHead
        }
        do {
            try track.insertTimeRange(
                CMTimeRange(start: time(start), duration: CMTime(seconds: sourceDuration, preferredTimescale: 600)),
                of: source,
                at: time(position)
            )
        } catch {
            return false
        }
        // 真素材那一段在时间线上的长度。被收口的部分按同一比例折算（= 取到的
        // 素材秒 ÷ 变速），画面和声音才不会错位。
        let realDuration = sourceDuration / max(0.05, clip.speed)
        if abs(clip.speed - 1) > 0.001 {
            track.scaleTimeRange(
                CMTimeRange(start: time(position), duration: CMTime(seconds: sourceDuration, preferredTimescale: 600)),
                toDuration: CMTime(seconds: realDuration, preferredTimescale: 600)
            )
        }
        position += realDuration
        if holdTail > 0.0005, isVideo {
            // 尾帧定格一直铺到这段的结尾：素材被收口短了一截时，差的那点也由
            // 定格补上，免得定格前面夹一条黑缝。声音不用插 —— 下一段插进来之前
            // 游标之后的空档会补空段，就是静音。
            let frame = await frameDuration(of: source)
            await insertHold(
                source: source, frameAt: max(start, start + sourceDuration - frame),
                duration: at + clip.timelineDuration - position, into: track, at: position
            )
        }
        cursor = at + clip.timelineDuration
        return true
    }

    /// 定格：把素材 `sourceTime` 处的**那一帧**插到 `at`，拉长成 `duration` 秒。
    /// 插不进去（素材读不出那一帧）就留一段空 —— 那一截露出下面的黑底，不至于
    /// 让后面的段整体错位。
    private static func insertHold(
        source: AVAssetTrack, frameAt sourceTime: Double, duration: Double,
        into track: AVMutableCompositionTrack, at: Double
    ) async {
        guard duration > 0.0005 else { return }
        let frame = CMTime(seconds: await frameDuration(of: source), preferredTimescale: 600)
        let target = CMTime(seconds: duration, preferredTimescale: 600)
        do {
            try track.insertTimeRange(
                CMTimeRange(start: time(sourceTime), duration: frame), of: source, at: time(at)
            )
            track.scaleTimeRange(CMTimeRange(start: time(at), duration: frame), toDuration: target)
        } catch {
            track.insertEmptyTimeRange(CMTimeRange(start: time(at), duration: target))
        }
    }

    /// 源轨一帧有多长（秒）。读不出来按 1/30。
    private static func frameDuration(of source: AVAssetTrack) async -> Double {
        if let min = try? await source.load(.minFrameDuration), min.isValid, min.seconds > 0 {
            return min.seconds
        }
        return 1.0 / 30
    }

    /// 素材画面摆进输出画布的完整变换：源自带旋转摆正 → 裁切区挪到原点 →
    /// 缩放（翻转就是负缩放）→ 绕摆放框中心旋转 → 平移到摆放框。
    /// 摆放框：用户摆过的（placement）优先，否则默认布局（等比铺满居中，按
    /// **裁后的**宽高比）—— 主轨和上层视频轨同一份账，不再分叉。返回的
    /// cropRect 是换算回源轨自然坐标系的裁切矩形，layer instruction 用它真正
    /// 剪掉框外像素。
    private static func fittingTransform(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        renderSize: CGSize,
        clip: EditClip
    ) -> (transform: CGAffineTransform, cropRect: CGRect?, geometry: ClipGeometry?) {
        let bounds = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let display = CGSize(width: abs(bounds.width), height: abs(bounds.height))
        guard display.width > 0, display.height > 0 else { return (.identity, nil, nil) }

        // 显示方向上的裁切区（没裁就是整幅）。
        let hasCrop = !(clip.crop?.isEmpty ?? true)
        let source = clip.crop.flatMap { $0.isEmpty ? nil : $0.rect(in: display) }
            ?? CGRect(origin: .zero, size: display)
        let geometry = ClipGeometry(
            preferredTransform: preferredTransform,
            boundsOrigin: CGPoint(x: bounds.minX, y: bounds.minY),
            sourceRect: source
        )

        // 摆放框：placement 或按裁后宽高比的默认布局。
        // 注意别用 clip.defaultPlacement —— 那个基于 probe 的 displaySize，
        // 和这里从源轨实测的尺寸可能差一两个像素，两边要用同一份。
        let target: CGRect
        if clip.needsPerFrameRender || clip.placement != nil {
            // 动画段（关键帧或预设入/出场，以及摆过的段）统一走归一化摆放：
            // 和预览里的交互框完全同一套换算，动画哪个分量没打关键帧就用它的
            // 静态/默认值。逐片重算的基准（`composedTransform`）读的也是这一份，
            // 两处必须同源，否则动画结束的那一帧会跳一两个像素。
            target = clip.animatedPlacement(atTimeline: clip.timelineStart, canvas: renderSize)
                .frame(in: renderSize)
        } else {
            let scale = min(renderSize.width / source.width, renderSize.height / source.height)
            let size = CGSize(width: source.width * scale, height: source.height * scale)
            target = CGRect(
                x: (renderSize.width - size.width) / 2,
                y: (renderSize.height - size.height) / 2,
                width: size.width,
                height: size.height
            )
        }

        let transform = placedTransform(
            geometry: geometry,
            target: target,
            rotationDegrees: clip.rotationDegrees,
            flippedHorizontally: clip.flippedHorizontally,
            flippedVertically: clip.flippedVertically
        )

        // 裁切矩形换算回自然坐标：显示矩形先挪回包围盒位置，再逆着源旋转变换。
        var cropRect: CGRect?
        if hasCrop {
            cropRect = source
                .offsetBy(dx: bounds.minX, dy: bounds.minY)
                .applying(preferredTransform.inverted())
                .standardized
        }
        return (transform, cropRect, clip.needsPerFrameRender ? geometry : nil)
    }

    /// 给定摆放框和旋转角，算完整变换（几何量固定，动画每片重算时只换这两个）。
    private static func placedTransform(
        geometry: ClipGeometry,
        target: CGRect,
        rotationDegrees: Double,
        flippedHorizontally: Bool,
        flippedVertically: Bool
    ) -> CGAffineTransform {
        let source = geometry.sourceRect
        guard source.width > 0, source.height > 0, target.width > 0, target.height > 0 else {
            return .identity
        }
        var transform = geometry.preferredTransform
            .concatenating(CGAffineTransform(translationX: -geometry.boundsOrigin.x, y: -geometry.boundsOrigin.y))
            .concatenating(CGAffineTransform(translationX: -source.minX, y: -source.minY))
            .concatenating(CGAffineTransform(
                scaleX: target.width / source.width * (flippedHorizontally ? -1 : 1),
                y: target.height / source.height * (flippedVertically ? -1 : 1)
            ))
        if flippedHorizontally || flippedVertically {
            transform = transform.concatenating(CGAffineTransform(
                translationX: flippedHorizontally ? target.width : 0,
                y: flippedVertically ? target.height : 0
            ))
        }
        if abs(rotationDegrees) > 0.01 {
            let radians = rotationDegrees * .pi / 180
            transform = transform
                .concatenating(CGAffineTransform(translationX: -target.width / 2, y: -target.height / 2))
                .concatenating(CGAffineTransform(rotationAngle: radians))
                .concatenating(CGAffineTransform(translationX: target.width / 2, y: target.height / 2))
        }
        return transform.concatenating(CGAffineTransform(translationX: target.minX, y: target.minY))
    }

    /// 某时刻这一段的完整变换：**关键帧摆放 ⊕ 预设动画 ⊕ 推移转场的平移**。
    ///
    /// 三者叠在一起而不是三选一：关键帧给基准摆放框，预设动画在这个框上叠位移和
    /// 缩放（所以动画跑着也不改存下来的摆放值 —— 预览里的选中框不会跟着飞），
    /// 推移转场是整幅画布的平移，最后乘上去。没有几何量（`geometry == nil`）的段
    /// 就是静态段，直接用建表时算好的那一份。
    private static func composedTransform(
        _ item: PlacedClip,
        at timelineTime: Double,
        renderSize: CGSize
    ) -> CGAffineTransform {
        var base = item.transform
        if let geometry = item.geometry {
            let clamped = min(max(timelineTime, item.start), item.end)
            var target = item.clip
                .animatedPlacement(atTimeline: clamped, canvas: renderSize)
                .frame(in: renderSize)
            if !item.preset.isEmpty {
                target = item.clip
                    .presetState(resolved: item.preset, atTimeline: clamped, canvas: renderSize)
                    .apply(to: target)
            }
            base = placedTransform(
                geometry: geometry,
                target: target,
                rotationDegrees: item.clip.animatedRotation(atTimeline: clamped),
                flippedHorizontally: item.clip.flippedHorizontally,
                flippedVertically: item.clip.flippedVertically
            )
        }
        // 推移转场的平移窗口边界都在切片表里，片内平移线性，端点求值 + 矩阵斜坡
        // 就是精确重建（平移分量线性插值无误差）。
        let push = pushTranslation(item, at: timelineTime)
        guard push.dx != 0 || push.dy != 0 else { return base }
        return base.concatenating(CGAffineTransform(translationX: push.dx, y: push.dy))
    }

    /// 某时刻这一段的裁切矩形（源轨自然坐标）：**擦除转场 ∩ 用户裁切 ∩ 预设擦除**。
    ///
    /// 擦除转场那条已经把用户裁切求过交（`wipeCropRect`）；预设擦除揭开的是
    /// **素材自己的框**（`geometry.sourceRect` 本来就是裁后的区域），所以再求一次交
    /// 就够。两个擦除在时间上永远不重叠 —— 接缝上有转场时那一侧的预设动画
    /// 已经被 `ClipPreset.effective` 仲裁掉了。
    private static func cropRectangle(
        _ item: PlacedClip, at timelineTime: Double, renderSize: CGSize
    ) -> CGRect? {
        let base = wipeCropRect(item, at: timelineTime, renderSize: renderSize)
        guard item.preset.usesWipe else { return base }
        // 窗口外读不到 reveal，那就是**整幅**（1）—— 见 `usesWipe` 的注释：
        // 这一片不给矩形的话整条裁切斜坡就断了。
        let reveal = item.clip
            .presetState(resolved: item.preset, atTimeline: timelineTime, canvas: renderSize)
            .reveal ?? 1
        guard let revealed = revealCropRect(item, reveal: reveal) else { return base }
        return base.map { clampedIntersection($0, revealed) } ?? revealed
    }

    /// 预设擦除在某个进度下露出来的源矩形（自然坐标）。
    ///
    /// 只揭**横向**、从左往右：与文字的 `wipe` 同口径。左右是**显示方向**上的
    /// 左右，所以换算路径和 `fittingTransform` 里算 `cropRect` 的那条一字不差：
    /// 显示矩形挪回包围盒位置，再逆着源自带旋转变换。
    private static func revealCropRect(_ item: PlacedClip, reveal: Double) -> CGRect? {
        guard let geometry = item.geometry else { return nil }
        let source = geometry.sourceRect
        guard source.width > 0, source.height > 0 else { return nil }
        // 揭到 0 时留 1px：零宽矩形喂给 setCropRectangle 属于退化输入，
        // 而 1px 的竖条在任何分辨率下都看不见。
        let width = max(1, source.width * min(max(reveal, 0), 1))
        return CGRect(x: source.minX, y: source.minY, width: width, height: source.height)
            .offsetBy(dx: geometry.boundsOrigin.x, dy: geometry.boundsOrigin.y)
            .applying(geometry.preferredTransform.inverted())
            .standardized
    }

    /// 剪辑范围内的恒定音量；两端按 `fades` 做线性斜坡。
    ///
    /// `fades` 里已经把「用户设的渐入渐出」和「转场重叠区的交叉淡变」仲裁完了
    /// （`AudioFadeWindow.previewMainTrack`），这里只管照着铺斜坡 —— 别在这个
    /// 函数里再判断转场，两处判断迟早会分叉。
    ///
    /// `previousEnd` 是**同一条合成轨上**上一段的结束点，用来给下面的「提前钉
    /// 音量」找落点，不能越过它去动上一段的尾巴。
    private static func addVolumeRamps(
        params: AVMutableAudioMixInputParameters,
        clip: EditClip,
        fades: AudioFadeWindow,
        previousEnd: Double,
        gainScale: Double
    ) {
        // 画了音量曲线的段走折线表（与导出同一张），没画的段一行不变地走老路。
        if clip.hasVolumeCurve {
            addCurveRamps(
                params: params, clip: clip, fades: fades, previousEnd: previousEnd, gainScale: gainScale
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
        params.setVolume(fadeIn == nil ? volume : 0, at: time(pin))

        var bodyStart = clip.timelineStart
        var bodyEnd = clip.timelineEnd
        if let fadeIn, fadeIn > 0 {
            params.setVolumeRamp(
                fromStartVolume: 0, toEndVolume: volume,
                timeRange: CMTimeRange(start: time(clip.timelineStart), end: time(clip.timelineStart + fadeIn))
            )
            bodyStart += fadeIn
        }
        if let fadeOut, fadeOut > 0 { bodyEnd -= fadeOut }
        if bodyEnd > bodyStart {
            params.setVolumeRamp(
                fromStartVolume: volume, toEndVolume: volume,
                timeRange: CMTimeRange(start: time(bodyStart), end: time(bodyEnd))
            )
        }
        if let fadeOut, fadeOut > 0 {
            params.setVolumeRamp(
                fromStartVolume: volume, toEndVolume: 0,
                timeRange: CMTimeRange(start: time(clip.timelineEnd - fadeOut), end: time(clip.timelineEnd))
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
        params: AVMutableAudioMixInputParameters,
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
        params.setVolume(gain(0), at: time(pin))
        // 相邻两点落在同一个 1/600 秒格子里就并掉（零长斜坡 AVFoundation 不认）。
        var last: (time: CMTime, gain: Float) = (time(clip.timelineStart), gain(0))
        for offset in times {
            let at = time(clip.timelineStart + offset)
            let value = gain(offset)
            guard CMTimeCompare(at, last.time) > 0 else {
                last.gain = value
                continue
            }
            params.setVolumeRamp(
                fromStartVolume: last.gain, toEndVolume: value,
                timeRange: CMTimeRange(start: last.time, end: at)
            )
            last = (at, value)
        }
    }

    /// 渐变窗口里细分多少份（见 `addCurveRamps`）。
    static let fadeSubdivisions = 16

    /// 按所有段落的边界切片，每一片描述「此刻谁可见、透明度怎么变」。
    private static func buildVideoComposition(
        placed: [PlacedClip],
        renderSize: CGSize,
        totalDuration: Double,
        frameRate: ProjectFrameRate
    ) -> AVMutableVideoComposition {
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        // 工程帧率是唯一事实来源；这里以前写死 1/30。
        let d = frameRate.frameDurationRational
        videoComposition.frameDuration = CMTime(value: d.value, timescale: d.timescale)

        var boundaries: Set<Double> = [0, totalDuration]
        for item in placed {
            boundaries.insert(item.start)
            boundaries.insert(item.end)
            if let fadeIn = item.fadeIn {
                boundaries.insert(item.start + fadeIn.duration)
                boundaries.insert(item.start + fadeIn.duration / 2)
            }
            if let fadeOut = item.fadeOut {
                boundaries.insert(item.end - fadeOut.duration)
                boundaries.insert(item.end - fadeOut.duration / 2)
            }
            if let pushIn = item.pushIn { boundaries.insert(item.start + pushIn.duration) }
            if let pushOut = item.pushOut { boundaries.insert(item.end - pushOut.duration) }
            if let wipeOut = item.wipeOut {
                boundaries.insert(item.end - wipeOut.duration)
                addWipeCropBoundaries(for: item, renderSize: renderSize, into: &boundaries)
            }
            addAnimationBoundaries(for: item, frameRate: frameRate, into: &boundaries)
            // 预设入/出场：窗口端点必进，带缓动的效果还要在窗口内按帧加密
            // （斜坡只会线性，曲线得靠密集折线逼近）。判据在 ClipAnimator 里。
            for boundary in ClipAnimator.sliceTimes(
                resolved: item.preset, clipStart: item.start,
                span: item.clip.timelineDuration, frameRate: frameRate
            ) where boundary > item.start + 0.0005 && boundary < item.end - 0.0005 {
                boundaries.insert(boundary)
            }
        }
        let times = boundaries.filter { $0 >= 0 && $0 <= totalDuration }.sorted()

        var instructions: [AVMutableVideoCompositionInstruction] = []
        for index in 0..<(max(1, times.count) - 1) {
            let sliceStart = times[index]
            let sliceEnd = times[index + 1]
            guard sliceEnd - sliceStart > 0.0005 else { continue }
            let middle = (sliceStart + sliceEnd) / 2

            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: time(sliceStart), end: time(sliceEnd))
            instruction.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)

            // 可见的段：层级高的排前面（layerInstructions 第一个在最上面）。
            let active = placed
                .filter { $0.start - 0.0005 <= middle && middle < $0.end + 0.0005 && !$0.clip.isAudioOnly }
                .sorted { lhs, rhs in
                    if lhs.layer != rhs.layer { return lhs.layer > rhs.layer }
                    // 主轨重叠区：出场的那段画在上面，淡出后露出下面的进场段。
                    return lhs.start > rhs.start ? false : true
                }

            var layers: [AVMutableVideoCompositionLayerInstruction] = []
            for item in active {
                let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: item.track)
                // 变换和裁切都走「端点求值 + 斜坡」：切片表里已经含了所有折点
                // （关键帧、预设窗口与其加密点、推移/擦除窗口、求交折点），
                // 片内每条通道都是线性的，两端取值就是精确重建。
                let fromTransform = composedTransform(item, at: sliceStart, renderSize: renderSize)
                let toTransform = composedTransform(item, at: sliceEnd, renderSize: renderSize)
                if fromTransform == toTransform {
                    layer.setTransform(fromTransform, at: time(sliceStart))
                } else {
                    layer.setTransformRamp(
                        fromStart: fromTransform,
                        toEnd: toTransform,
                        timeRange: CMTimeRange(start: time(sliceStart), end: time(sliceEnd))
                    )
                }
                if let fromCrop = cropRectangle(item, at: sliceStart, renderSize: renderSize),
                   let toCrop = cropRectangle(item, at: sliceEnd, renderSize: renderSize) {
                    if fromCrop.equalTo(toCrop) {
                        layer.setCropRectangle(fromCrop, at: time(sliceStart))
                    } else {
                        layer.setCropRectangleRamp(
                            fromStartCropRectangle: fromCrop,
                            toEndCropRectangle: toCrop,
                            timeRange: CMTimeRange(start: time(sliceStart), end: time(sliceEnd))
                        )
                    }
                }
                applyOpacity(layer, item: item, sliceStart: sliceStart, sliceEnd: sliceEnd, renderSize: renderSize)
                layers.append(layer)
            }
            instruction.layerInstructions = layers
            instructions.append(instruction)
        }

        videoComposition.instructions = instructions
        return videoComposition
    }

    /// 动画段的额外切片边界：位置/缩放/不透明度的斜坡本身是精确线性，
    /// 只要在每个关键帧处断片；旋转斜坡是矩阵线性插值（走弦不走弧，角度大了
    /// 明显缩小变形），相邻帧之间按 ≤6°/片加密；不透明度动画和转场衰减相乘
    /// 是二次曲线，斜坡只会线性，转场窗口内按 0.1s 加密补齐。
    private static func addAnimationBoundaries(for item: PlacedClip, frameRate: ProjectFrameRate, into boundaries: inout Set<Double>) {
        guard let animation = item.clip.animation, !animation.isEmpty else { return }
        let clip = item.clip

        func insert(_ timelineTime: Double) {
            if timelineTime > item.start + 0.0005, timelineTime < item.end - 0.0005 {
                boundaries.insert(timelineTime)
            }
        }

        // source 空间去重容差含 speed（见 KeyframeTrack.sourceTolerance）
        let keyTol = KeyframeTrack.sourceTolerance(frameRate: frameRate, speed: clip.speed)
        for sourceTime in animation.allKeyTimes(tolerance: keyTol) {
            insert(clip.timelineTime(atSource: sourceTime))
        }

        let rotationKeys = animation.rotation.keys
        if rotationKeys.count >= 2 {
            for index in 1..<rotationKeys.count {
                let a = rotationKeys[index - 1]
                let b = rotationKeys[index]
                // 单段最多 400 片：十几圈的疯转宁可略糙，别把指令表撑爆。
                let steps = min(400, Int((abs(b.value - a.value) / 6).rounded(.up)))
                guard steps > 1 else { continue }
                for step in 1..<steps {
                    let sourceTime = a.time + (b.time - a.time) * Double(step) / Double(steps)
                    insert(clip.timelineTime(atSource: sourceTime))
                }
            }
        }

        if !animation.opacity.isEmpty {
            var windows: [(Double, Double)] = []
            if let fadeIn = item.fadeIn { windows.append((item.start, item.start + fadeIn.duration)) }
            if let fadeOut = item.fadeOut { windows.append((item.end - fadeOut.duration, item.end)) }
            for window in windows {
                var t = window.0
                while t < window.1 {
                    insert(t)
                    t += 0.1
                }
            }
        }
    }

    /// 一片时间里这段画面的透明度。转场的淡入淡出斜坡整体乘上剪辑自己的
    /// 不透明度（Transform 面板的 Opacity，可能带关键帧），两套互不干扰。
    private static func applyOpacity(
        _ layer: AVMutableVideoCompositionLayerInstruction,
        item: PlacedClip,
        sliceStart: Double,
        sliceEnd: Double,
        renderSize: CGSize
    ) {
        // 切片边界包含了所有折点（淡变起止/半程、关键帧、加密点），所以片内
        // 两个通道都是线性，端点求值就能精确重建整片；乘积的二次误差由
        // 0.1s 加密压到不可见。
        func opacity(at timelineTime: Double) -> Float {
            let clamped = min(max(timelineTime, item.start), item.end)
            var value = fadeFactor(item: item, at: timelineTime)
                * Float(item.clip.animatedOpacity(atTimeline: clamped))
            if !item.preset.isEmpty {
                // 预设动画的头尾淡变（`.fade` 是线性斜坡、位移/缩放类自带缓动）。
                // 它和上面的 `fadeFactor` 互斥：要逐帧的效果不会再挂 fadeIn/fadeOut。
                value *= Float(item.clip
                    .presetState(resolved: item.preset, atTimeline: clamped, canvas: renderSize)
                    .opacity)
            }
            return value
        }
        let from = opacity(at: sliceStart)
        let to = opacity(at: sliceEnd)
        if abs(from - to) < 0.0005 {
            layer.setOpacity(from, at: time(sliceStart))
        } else {
            layer.setOpacityRamp(
                fromStartOpacity: from, toEndOpacity: to,
                timeRange: CMTimeRange(start: time(sliceStart), end: time(sliceEnd))
            )
        }
    }

    /// 转场淡入淡出在某时刻的衰减系数（0…1，片内线性）。
    private static func fadeFactor(item: PlacedClip, at timelineTime: Double) -> Float {
        var factor = 1.0
        if let fadeIn = item.fadeIn {
            let fadeStart = fadeIn.delayedHalf ? item.start + fadeIn.duration / 2 : item.start
            let fadeEnd = item.start + fadeIn.duration
            if timelineTime <= fadeStart {
                factor = 0
            } else if timelineTime < fadeEnd {
                factor = min(factor, (timelineTime - fadeStart) / max(0.001, fadeEnd - fadeStart))
            }
        }
        if let fadeOut = item.fadeOut {
            let fadeStart = item.end - fadeOut.duration
            let fadeEnd = fadeOut.earlyHalf ? item.end - fadeOut.duration / 2 : item.end
            if timelineTime >= fadeEnd {
                factor = 0
            } else if timelineTime > fadeStart {
                factor = min(factor, 1 - (timelineTime - fadeStart) / max(0.001, fadeEnd - fadeStart))
            }
        }
        return Float(min(max(factor, 0), 1))
    }

    // MARK: 推移 / 擦除转场的几何

    /// 推移能精确复刻 xfade slide 的前提：换算完的矩阵轴对齐（90° 的
    /// preferredTransform、翻转、任何缩放都算；任意角旋转不算）且不是关键帧
    /// 动画段（动画的「画布裁切」没法逐片跟着变换走）。半透明/盖不满都不用管：
    /// 黑底垫着，逐像素等于「压平到黑底再整幅滑动」。
    private static func pushSideExact(_ clip: EditClip, _ transform: CGAffineTransform) -> Bool {
        // 预设入/出场动画的段和关键帧段一样保守回退：推移的精确路径要先把这段
        // 「压平到静止时的画布」再整幅滑动（`clampCropToCanvas`），而那份裁切是
        // 按静态变换算的 —— 段里别处还在做位移/缩放的话，动起来就会被裁掉一块。
        !clip.needsPerFrameRender && isAxisAlignedInvertible(transform)
    }

    /// 轴对齐且可逆：画布矩形经它逆映射后仍是矩形，`setCropRectangle` 才表达得了。
    private static func isAxisAlignedInvertible(_ t: CGAffineTransform) -> Bool {
        guard abs(t.a * t.d - t.b * t.c) > 1e-9 else { return false }
        return (abs(t.b) < 1e-6 && abs(t.c) < 1e-6) || (abs(t.a) < 1e-6 && abs(t.d) < 1e-6)
    }

    /// 把这段的裁切收进「静止时的画布」（换算回源坐标）。推移的压平模型里，
    /// 滑出画布的内容不会被滑回来看见 —— 不裁的话放大出画布的段一滑就穿帮。
    private static func clampCropToCanvas(_ item: inout PlacedClip, renderSize: CGSize) {
        let mapped = CGRect(origin: .zero, size: renderSize)
            .applying(item.transform.inverted())
            .standardized
        item.cropRect = item.cropRect.map { clampedIntersection($0, mapped) } ?? mapped
    }

    /// 交集恒返回矩形：分离时贴边给近零尺寸 —— 裁切斜坡要连续，不能蹦出 .null。
    private static func clampedIntersection(_ a: CGRect, _ b: CGRect) -> CGRect {
        let minX = max(a.minX, b.minX)
        let minY = max(a.minY, b.minY)
        let maxX = min(a.maxX, b.maxX)
        let maxY = min(a.maxY, b.maxY)
        return CGRect(x: minX, y: minY, width: max(0.001, maxX - minX), height: max(0.001, maxY - minY))
    }

    /// 推移转场在某时刻的画布平移（窗口内线性，窗口外为零；窗口边界都在
    /// 切片表里，片内就是精确线性）。
    private static func pushTranslation(_ item: PlacedClip, at timelineTime: Double) -> (dx: CGFloat, dy: CGFloat) {
        var dx: CGFloat = 0
        var dy: CGFloat = 0
        if let push = item.pushIn, timelineTime < item.start + push.duration {
            let u = min(max((timelineTime - item.start) / max(push.duration, 0.001), 0), 1)
            dx += push.fromDX * CGFloat(1 - u)
            dy += push.fromDY * CGFloat(1 - u)
        }
        if let push = item.pushOut {
            let windowStart = item.end - push.duration
            if timelineTime > windowStart {
                let u = min(max((timelineTime - windowStart) / max(push.duration, 0.001), 0), 1)
                dx += push.toDX * CGFloat(u)
                dy += push.toDY * CGFloat(u)
            }
        }
        return (dx, dy)
    }

    /// 擦除转场在某时刻的源坐标裁切矩形（窗口 ∩ 用户裁切）。窗口开始前
    /// 就是整幅画布 —— 裁到画布对画面没有可见影响（画布外本来就看不见）。
    private static func wipeCropRect(_ item: PlacedClip, at timelineTime: Double, renderSize: CGSize) -> CGRect? {
        guard let wipe = item.wipeOut else { return item.cropRect }
        let windowStart = item.end - wipe.duration
        let progress = min(max((timelineTime - windowStart) / max(wipe.duration, 0.001), 0), 1)
        let mapped = wipe.kind
            .wipeRemainingRect(progress: progress, canvas: renderSize)
            .applying(item.transform.inverted())
            .standardized
        return item.cropRect.map { clampedIntersection($0, mapped) } ?? mapped
    }

    /// 擦除窗口和用户裁切求交，交集的边是 min/max：移动边扫过用户裁切边的
    /// 时刻各有一个折点，必须进切片表 —— 否则整窗一条斜坡会把「先不动、
    /// 后缩空」拉直成匀速。
    private static func addWipeCropBoundaries(
        for item: PlacedClip, renderSize: CGSize, into boundaries: inout Set<Double>
    ) {
        guard let wipe = item.wipeOut, let crop = item.cropRect, let motion = wipe.kind.motion else { return }
        let cropCanvas = crop.applying(item.transform).standardized
        let windowStart = item.end - wipe.duration
        let horizontal = motion.dx != 0
        let span = horizontal ? renderSize.width : renderSize.height
        guard span > 0 else { return }
        let positions = horizontal ? [cropCanvas.minX, cropCanvas.maxX] : [cropCanvas.minY, cropCanvas.maxY]
        for position in positions {
            // 移动边的位置：dx<0 在 W(1-p)、dx>0 在 W·p（dy 同理，见
            // wipeRemainingRect）。反解出经过 position 的进度。
            let fraction = Double(position / span)
            let progress = (motion.dx < 0 || motion.dy < 0) ? 1 - fraction : fraction
            let crossing = windowStart + wipe.duration * progress
            if crossing > windowStart + 0.0005, crossing < item.end - 0.0005 {
                boundaries.insert(crossing)
            }
        }
    }
}
