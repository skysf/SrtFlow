import Foundation

// 性能测试的固定场景（docs/architecture/preview-perf-ratchet.md）。
//
// 素材由 scripts/check-preview-perf.sh 在 CI 上现生成（固定参数的软件编码），文件名
// 写死在 `Media` 里。搭场景只走和界面按钮同一批入口（addVideos / attachSubtitle /
// setTransition / perform …），不手写工程文件 —— 工程格式改了，场景照样对。
//
// **改场景就会改数。** 那样的 PR 只许动 PreviewBench*.swift，基线跟着重定
//（check-preview-perf.sh 认这条路，见架构文档「只许降」一节）。

@MainActor
enum PreviewBenchScenario: String, CaseIterable {
    /// 主轨一段素材，别的什么都没有：编辑器本身的底账。
    case basic
    /// 一个常见的剪辑工程：三段主轨带转场；一段上层视频缩小摆在角上、半透明、带入场
    /// 动画；背景音乐带渐入和音量曲线；字幕、文字、形状、一段滤镜；选中一段主轨素材。
    case busy

    enum Media {
        static let main = ["main1.mp4", "main2.mp4", "main3.mp4"]
        static let overlay = "overlay.mp4"
        static let music = "music.m4a"
        static let subtitles = "subs.srt"
    }

    /// 时钟连跳从哪一刻起跳（跳 60 下、每下 0.05 秒 —— 正好是播放时的节奏）。
    var tickStart: Double {
        switch self {
        case .basic: return 1.0
        case .busy: return 2.0
        }
    }

    func build(on project: VideoEditProject, media: URL) async throws {
        let file = { (name: String) in media.appendingPathComponent(name) }
        switch self {
        case .basic:
            await project.addVideos([file(Media.main[0])], toOverlay: false)
            try require(project.state.mainClips.count == 1, "主轨素材没导进来")

        case .busy:
            await project.addVideos(Media.main.map(file), toOverlay: false)
            try require(project.state.mainClips.count == 3, "主轨素材没导全")
            let main = project.state.mainClips.map(\.id)

            // 上层视频落在播放头上（addVideos 的规则），所以先把播放头挪过去。
            project.clock.seek(to: 2.0)
            await project.addVideos([file(Media.overlay)], toOverlay: true)
            project.clock.seek(to: 0)
            await project.addAudios([file(Media.music)])
            project.attachSubtitle(file(Media.subtitles))
            guard let overlay = project.state.overlayTracks.first?.clips.first?.id,
                  let music = project.state.audioTracks.first?.clips.first?.id else {
                throw PreviewBench.Failure("上层视频或背景音乐没导进来")
            }
            try require(project.state.subtitle != nil, "字幕没挂上")

            project.setTransition(after: main[0], .crossFade, duration: 1.0)
            project.setTransition(after: main[1], .pushLeft, duration: 0.8)
            project.setPlacement(overlay, ClipPlacement(centerX: 0.75, centerY: 0.28, width: 0.4, height: 0.4))
            project.setClipOpacity(overlay, 0.85)
            project.setClipPresetKind([overlay], edge: .fadeIn, kind: .pop)
            project.setAudioFade(music, edge: .fadeIn, seconds: 1.5)
            project.addVolumePoint(music, atTimeline: 6)
            project.addVolumePoint(music, atTimeline: 12)
            project.addFilter(.tealOrange, at: 4, duration: 6, layer: 0)
            // 文字和形状直接追加：`addTextOverlay()` 会顺手浮出输入框进入编辑态，
            // 那会改掉键盘路由，和「剪辑中途看预览」不是同一个状态。
            project.perform(rebuildsPreview: false) { state in
                state.textOverlays.append(TextOverlay(text: "SrtFlow", timelineStart: 1, duration: 4))
                state.shapes.append(ShapeAnnotation(kind: .rectangle, timelineStart: 3, duration: 4))
            }
            project.select(main[1], additive: false)
        }
        project.clock.seek(to: tickStart)
    }

    /// 编辑阶段的几刀，每刀之后等预览落定（`settle`）再下一刀。
    ///
    /// 挑的是最常见、代价差别最大的三类：只换 audioMix 的快路径（改音量）、
    /// 要重建整条合成的（挪上层视频、改转场时长、变速）、只动叠层不碰合成的（改文字）。
    func edits(on project: VideoEditProject, settle: () async throws -> Void) async throws {
        switch self {
        case .basic:
            guard let clip = project.state.mainClips.first?.id else {
                throw PreviewBench.Failure("主轨素材不见了")
            }
            project.setVolume(clip, volume: 0.8)
            try await settle()
            project.setSpeed(clip, speed: 1.25)
            try await settle()

        case .busy:
            guard let music = project.state.audioTracks.first?.clips.first?.id,
                  let overlay = project.state.overlayTracks.first?.clips.first?.id,
                  let first = project.state.mainClips.first?.id,
                  let text = project.state.textOverlays.first?.id else {
                throw PreviewBench.Failure("场景里的素材不见了")
            }
            project.setVolume(music, volume: 0.8)
            try await settle()
            project.perform { state in
                state.update(overlay) { $0.timelineStart += 0.5 }
            }
            try await settle()
            project.setTransition(after: first, .crossFade, duration: 0.6)
            try await settle()
            project.updateTextOverlay(text) { $0.text = "SrtFlow bench" }
            try await settle()
        }
    }

    private func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw PreviewBench.Failure(message) }
    }
}
