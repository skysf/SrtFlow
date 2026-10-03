import AVFoundation
import Foundation
import SrtFlowCore

/// 把时间线状态翻译成 AVFoundation 的预览合成。
///
/// 结构：主轨用**两条**合成视频轨 A/B 交替放段落 —— 转场要求前后两段在重叠区
/// 同时有画面，同一条轨做不到。上层视频轨每条时间线轨各占一条合成轨。转场用
/// 透明度渐变近似（压黑/闪白在导出时由 xfade 精确渲染，预览的时间账完全一致）。
/// 变速用 scaleTimeRange。**合成里只有画面**：声音全在音频引擎里（AudioEngine/，预览实时渲、成片离线渲），
/// 画面从原片取，或者（只有预览重建传 `proxies` 时）从优化媒体的块取（CompositionClipInsert，docs/architecture/optimized-media.md）。
/// 2026-10-01 PR3b 之前这里还插合成音轨、铺 audioMix。画面收得比时间线总长早（配乐比画面长、纯音频时间线）时
/// 垫一截黑底铺到总长：播放器的条目要和时间线一样长，不然播到画面结尾就停在最后一帧上、时钟对表也没完没了。
enum VideoEditCompositionBuilder {

    struct Built {
        var composition: AVMutableComposition
        var videoComposition: AVMutableVideoComposition?
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
    /// - Parameter proxies: 优化媒体转好的块；只有预览重建传（成片、预渲染、AI 看永远用原片）。
    static func build(
        from state: TimelineState,
        renderSizeOverride: CGSize? = nil,
        proxies: OptimizedMediaLookup = .none
    ) async -> Built? {
        // 主轨按数组顺序进 A/B 轨，插入游标只会前进：乱序的输入会让
        // `insertTimeRange` 把已插好的段往后挤（黑屏/画面错时）。状态侧的
        // 改动入口已维持有序，这里再守一道 —— 上层视频轨（下面）同款 sorted。
        PerfCounters.event(.compositionBuild)
        // 声音的配置另从用户那一份状态算（`AudioEngineConfig.make` 自己展开，展开只许一次）。
        let requested = state
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

        // 素材跨 build 走进程级缓存（`MediaAssetCache`，按路径 + inode + 卷认）；计数只记真开了文件的那几次。
        var assets: [URL: AVURLAsset] = [:]
        func asset(for url: URL) -> AVURLAsset {
            if let existing = assets[url] { return existing }
            let hit = MediaAssetCache.asset(for: url)
            if hit.opened { PerfCounters.event(.compositionAssetOpen) }
            assets[url] = hit.asset
            return hit.asset
        }

        // MARK: 主轨（A/B 交替）

        let videoA = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        let videoB = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        var videoCursors: [Double] = [0, 0]
        // 主轨 clip 序号 → placed 序号（接缝后处理用；被跳过的段不在里面）。
        var placedIndexByMainIndex: [Int: Int] = [:]
        // 上一段进了合成的主轨段收在哪（时间线秒）：接缝的零头要接在它真正的末尾上。
        var previousMainEnd = 0.0

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

            // 不到 `mainGapTolerance` 的缝不是空隙（成片的分节同一口径）：接在前一段真正的末尾上。前一段收在
            // 19.9598、这一段从 19.96 起，各自截断落在相邻两格，A/B 两条轨之间就空出一格 —— 接缝上一帧黑。
            let gap = clip.timelineStart - previousMainEnd
            let startsAt = gap > 0 && gap < TimelineState.mainGapTolerance ? previousMainEnd : clip.timelineStart
            guard let geometrySource = await CompositionClipInsert.insert(
                original: sourceVideo, proxies: await proxyTracks(for: clip, in: proxies, asset: asset),
                clip: clip, into: videoTrack, cursor: &videoCursors[slot], at: startsAt
            ) else { continue }
            previousMainEnd = clip.timelineEnd

            let naturalSize = (try? await geometrySource.load(.naturalSize)) ?? renderSize
            let preferred = (try? await geometrySource.load(.preferredTransform)) ?? .identity
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
            var videoCursor = 0.0

            for clip in ClipVisibility.visible(lane.clips)
                .sorted(by: { $0.timelineStart < $1.timelineStart })
            where !clip.needsStillConversion {
                let sourceAsset = asset(for: clip.sourceURL)
                guard let sourceVideo = try? await sourceAsset.loadTracks(withMediaType: .video).first else { continue }
                guard let geometrySource = await CompositionClipInsert.insert(
                    original: sourceVideo, proxies: await proxyTracks(for: clip, in: proxies, asset: asset),
                    clip: clip, into: videoTrack, cursor: &videoCursor
                ) else { continue }

                let naturalSize = (try? await geometrySource.load(.naturalSize)) ?? renderSize
                let preferred = (try? await geometrySource.load(.preferredTransform)) ?? .identity
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
                // 切到混合路径（未覆盖区变暗绿色），必须垫黑底；带透明的静帧（透明处同样走混合路径）同理。
                || !$0.preset.isEmpty || $0.clip.isAlphaStill
        }
        // 画面收得比时间线早（配乐比画面长、纯音频时间线）：合成里没有音轨撑长度（声音在引擎里），播放器的条目
        // 就会比时间线短 —— 播到画面结尾停在最后一帧上，而引擎的播放头还在走、时钟每拍都去对表。所以从画面结尾
        // 到总长也垫黑底（只垫那一截：画面铺满的工程一层都不多，性能计数不变）。两种情况都要垫就整段垫。
        let pictureEnd = composition.tracks(withMediaType: .video)
            .map { CompositionTime.end(of: $0).seconds }.max() ?? 0
        let baseStart: Double? = needsOpaqueBase ? 0 : (pictureEnd + 0.0005 < state.duration ? pictureEnd : nil)
        if let baseStart, let baseURL = await BlackBaseVideoFactory.videoURL() {
            let baseAsset = asset(for: baseURL)
            let baseLength = state.duration - baseStart
            if let baseSource = try? await baseAsset.loadTracks(withMediaType: .video).first,
               let baseTrack = composition.addMutableTrack(
                   withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
               ),
               let sourceRange = try? await baseSource.load(.timeRange),
               ({ CompositionTime.pad(baseTrack, to: time(baseStart)); return true }()),
               (try? baseTrack.insertTimeRange(sourceRange, of: baseSource, at: time(baseStart))) != nil {
                baseTrack.scaleTimeRange(
                    CMTimeRange(start: time(baseStart), duration: sourceRange.duration),
                    toDuration: time(baseLength)
                )
                let natural = (try? await baseSource.load(.naturalSize)) ?? CGSize(width: 64, height: 36)
                var base = EditClip(sourceURL: baseURL, sourceDuration: baseLength)
                base.timelineStart = baseStart
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

        // 哪条合成轨比总长多出一格，视频合成就铺不满、判无效 → 预览黑屏（CompositionTime 第 3 条）。
        CompositionTime.trim(composition, to: time(state.duration))
        // 清掉没有任何内容的合成轨（A/B 双轨和音轨是无条件建的）。
        // AVPlayer 容忍空轨，AVAssetExportSession 会报 InvalidVideoComposition
        //（表述是 "Operation Stopped"）—— 预渲染走导出会话，必须干净。
        for track in composition.tracks where track.segments.isEmpty {
            composition.removeTrack(track)
        }
        // 没有任何画面（连黑底都没垫上）就不配 videoComposition。
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
            renderSize: renderSize
        )
    }

    // MARK: - 小工具

    private static func time(_ seconds: Double) -> CMTime { CompositionTime.tick(seconds) }  // 截断，别改成四舍五入

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

    /// 这一段的优化媒体块（都转好了才给；没有代理 / 没转全 / 块文件打不开 → nil，插原片）。只开真要用的那几块。
    private static func proxyTracks(
        for clip: EditClip, in lookup: OptimizedMediaLookup, asset: (URL) -> AVURLAsset
    ) async -> [Int: AVAssetTrack]? {
        guard let chunks = lookup.readyChunks(for: clip) else { return nil }
        var tracks: [Int: AVAssetTrack] = [:]
        for (chunk, url) in chunks {
            guard let track = try? await asset(url).loadTracks(withMediaType: .video).first else { return nil }
            tracks[chunk] = track
        }
        return tracks
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
        // 边界先落到格子上、按格子去重，指令表按构造首尾相接（CompositionSlices）：两个边界各自截断落在
        // 相邻两格、中间那片按秒算「太短不切」，指令表就空出一格 → 整个视频合成判无效 → 预览黑屏。
        var instructions: [AVMutableVideoCompositionInstruction] = []
        for slice in CompositionSlices.make(boundaries: boundaries, totalDuration: totalDuration) {
            let sliceStart = slice.start
            let sliceEnd = slice.end
            let middle = (sliceStart + sliceEnd) / 2

            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = slice.range
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
                    layer.setTransform(fromTransform, at: slice.range.start)
                } else {
                    layer.setTransformRamp(fromStart: fromTransform, toEnd: toTransform, timeRange: slice.range)
                }
                if let fromCrop = cropRectangle(item, at: sliceStart, renderSize: renderSize),
                   let toCrop = cropRectangle(item, at: sliceEnd, renderSize: renderSize) {
                    if fromCrop.equalTo(toCrop) {
                        layer.setCropRectangle(fromCrop, at: slice.range.start)
                    } else {
                        layer.setCropRectangleRamp(
                            fromStartCropRectangle: fromCrop, toEndCropRectangle: toCrop, timeRange: slice.range
                        )
                    }
                }
                applyOpacity(layer, item: item, slice: slice, renderSize: renderSize)
                layers.append(layer)
            }
            instruction.layerInstructions = layers
            instructions.append(instruction)
        }

        videoComposition.instructions = instructions
        return videoComposition
    }

    /// 动画段的额外切片边界：每个关键帧处断片、旋转按 ≤6°/片加密、带缓动的段按帧加密、不透明度动画在转场窗口里按 0.1s
    /// 加密 —— 规则和数字都在 KeyframeSliceTimes（纯值），这里只收进段内的开区间。
    private static func addAnimationBoundaries(for item: PlacedClip, frameRate: ProjectFrameRate, into boundaries: inout Set<Double>) {
        guard let animation = item.clip.animation, !animation.isEmpty else { return }
        var windows: [(start: Double, end: Double)] = []
        if let fadeIn = item.fadeIn { windows.append((item.start, item.start + fadeIn.duration)) }
        if let fadeOut = item.fadeOut { windows.append((item.end - fadeOut.duration, item.end)) }
        for time in KeyframeSliceTimes.times(animation: animation, clip: item.clip, frameRate: frameRate, fadeWindows: windows)
        where time > item.start + 0.0005 && time < item.end - 0.0005 {
            boundaries.insert(time)
        }
    }

    /// 一片时间里这段画面的透明度。转场的淡入淡出斜坡整体乘上剪辑自己的
    /// 不透明度（Transform 面板的 Opacity，可能带关键帧），两套互不干扰。
    private static func applyOpacity(
        _ layer: AVMutableVideoCompositionLayerInstruction,
        item: PlacedClip,
        slice: CompositionSlice,
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
        let from = opacity(at: slice.start)
        let to = opacity(at: slice.end)
        if abs(from - to) < 0.0005 {
            layer.setOpacity(from, at: slice.range.start)
        } else {
            layer.setOpacityRamp(fromStartOpacity: from, toEndOpacity: to, timeRange: slice.range)
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
