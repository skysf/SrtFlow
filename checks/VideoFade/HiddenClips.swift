import Foundation
import SrtFlowCore

// 藏起来的上层段不进成片：真导出、抽帧量像素。
// 管什么：上层视频轨上「整轨藏起来」和「单段按 V 藏起来」在 ffmpeg 导出里的样子。
// 不管什么：预览那条管线（`scripts/check-preview-composition.sh` 钉着）、主轨的隐藏（main.swift 之外的
// 工程自检和预览取帧钉着）。
//
// 2026-09-26 案例 docs/bugfixes/2026-09-26-hidden-upper-clip-still-exported.md：导出图里叠上层轨的
// 那一圈（连同预渲染那一圈）只滤了藏起来的轨、没滤藏起来的段 —— 预览里没了，成片里画面照旧在
// （声音走预览那份混音，早就滤掉了，所以只漏画面）。以前的守卫只扫「文件里出现过
// `ClipVisibility.visible(`」，主轨那一行就满足了。

/// 这一组的入口（main.swift 只调它一行）。
func checkHiddenClips(white: URL, black: URL, info: MediaInfo) async {
    await checkHiddenUpperClips(white: white, black: black, info: info)
    await checkTransitionIntoHiddenClip(white: white, black: black, info: info)
    await checkHiddenOverlaysStayOutOfExport(white: white, info: info)
}

/// 白色主轨上叠一段黑色上层视频（等比铺满画布）。四份：
/// - 没藏：**对照**。证明这个场景里上层段真的盖得住主轨 —— 否则「藏了之后中心是白」什么也说明不了；
/// - 按 V 藏了这一段；
/// - 按 V 藏了、还带着擦除入场（走预渲染那一圈，那一圈以前同样按轨取段）；
/// - 整条轨藏了（眼睛）：老路径，一起钉住，两级隐藏走的是同一份清单。
func checkHiddenUpperClips(white: URL, black: URL, info: MediaInfo) async {
    struct Case {
        var name: String
        var clipHidden = false
        var animated = false
        var laneHidden = false
        var expectsUpper: Bool { !clipHidden && !laneHidden }
    }
    let cases = [
        Case(name: "upper-visible"),
        Case(name: "upper-hidden", clipHidden: true),
        Case(name: "upper-hidden-animated", clipHidden: true, animated: true),
        Case(name: "upper-lane-hidden", laneHidden: true)
    ]
    for item in cases {
        var upper = EditClip(sourceURL: black, sourceDuration: 4, timelineStart: 0, info: info)
        upper.isHidden = item.clipHidden
        if item.animated { upper.presetAnimation.entrance = .wipe }
        var state = TimelineState()
        state.mainClips = [EditClip(sourceURL: white, sourceDuration: 4, timelineStart: 0, info: info)]
        state.overlayTracks = [EditLane(clips: [upper], isHidden: item.laneHidden)]
        guard let product = await export(state, name: "\(item.name).mp4"),
              let level = pixel(product, x: 32, y: 18, at: 3, name: item.name) else { continue }
        if item.expectsUpper {
            check(level < 0.3, "\(item.name)：没藏的上层段铺满画布，中心应当是它的黑，实测 \(level)")
        } else {
            check(level > 0.7, "\(item.name)：藏起来的上层段不许进成片，中心应当露出主轨的白，实测 \(level)")
        }
    }
}

/// 主轨接缝一侧被藏起来（V）：这条转场在渲染里不存在，活着的那一侧不许为它借余料、把自己拉长。
///
/// 2026-09-26 同一个案例的第二条：`expandingTransitionHandles()` 以前不看隐藏，照样把两边各展开 d/2。
/// 藏起来的那段随后被两条管线滤掉，活着的那段却已经多带了半个转场的余料（或定格）—— 预览和成片一起
/// 往藏起来的那段留下的黑场里多伸出一截。两个方向各测一份：前段活着（尾巴会被拉长）、后段活着（头会被提前）。
/// 每段 2 秒（素材 4 秒），转场 1 秒被容量夹到 0.8 秒。借料先从出场段的尾巴借：
/// - 前段活着：它取素材的 1–3 秒、尾巴有 1 秒余料 → 以前整段窗口都借它的尾巴，伸进后面那一格 0.8 秒；
/// - 后段活着：让藏起来的前段取素材最后 2 秒（尾巴一点余料都没有），窗口只能向活着的后段借头 →
///   以前后段提前 0.8 秒出场。反过来摆的话头一帧都不借，这个方向就测不出来（第一版就是这么漏的）。
func checkTransitionIntoHiddenClip(white: URL, black: URL, info: MediaInfo) async {
    func clip(_ url: URL, at start: Double, from sourceStart: Double, hidden: Bool) -> EditClip {
        var clip = EditClip(sourceURL: url, sourceDuration: 2, timelineStart: start, info: info)
        clip.sourceStart = sourceStart
        clip.isHidden = hidden
        return clip
    }
    for survivorFirst in [true, false] {
        // 活着的那段是白，藏起来的那段是黑 —— 藏起来之后那一格是画布的黑底，伸进去的白一眼就看得出来。
        var first = clip(survivorFirst ? white : black, at: 0, from: survivorFirst ? 1 : 2, hidden: !survivorFirst)
        first.transitionAfter = .crossFade
        first.transitionDuration = 1
        let second = clip(survivorFirst ? black : white, at: 2, from: 1, hidden: survivorFirst)
        var state = TimelineState()
        state.mainClips = [first, second]
        let name = survivorFirst ? "seam-hidden-after" : "seam-hidden-before"

        let rendered = state.expandingTransitionHandles()
        let survivor = survivorFirst ? 0 : 1
        check(abs(rendered.mainClips[survivor].timelineStart - state.mainClips[survivor].timelineStart) < 1e-9
              && abs(rendered.mainClips[survivor].timelineEnd - state.mainClips[survivor].timelineEnd) < 1e-9,
              "\(name)：一侧藏起来的缝不许展开，活着的那段在渲染副本里的起止要和时间线上一样")
        check(rendered.mainClips[0].transitionAfter == .none,
              "\(name)：一侧藏起来的缝在渲染副本里要摘掉转场")
        check(state.mainClips[0].transitionAfter == .crossFade, "\(name)：只改渲染副本，用户的工程原样")

        // 真导出：伸出去的那半个转场落在藏起来的那一格里（接缝 2 秒两侧各 0.25 秒处取样）。
        guard let product = await export(state, name: "\(name).mp4") else { continue }
        let probe = survivorFirst ? 2.25 : 1.75
        if let level = pixel(product, x: 32, y: 18, at: probe, name: name) {
            check(level < 0.3, "\(name)：\(probe)s 是藏起来的那一格，应当是黑场，实测 \(level)（活着的那段伸进来了）")
        }
        let own = survivorFirst ? 1.0 : 3.0
        if let level = pixel(product, x: 32, y: 18, at: own, name: "\(name)-own") {
            check(level > 0.7, "\(name)：\(own)s 是活着的那段自己的位置，应当是白，实测 \(level)")
        }
    }
}

/// 文字、形状、滤镜段按 V 藏起来（2026-09-26）：导出图里一点都不许有它们 —— 文字 PNG、形状 PNG、
/// lut3d 都不进参数。先跑一份都显示着的**对照**，证明这三样在这个场景里本来都会进图，否则「藏了之后
/// 没有」什么也说明不了。预览那一侧读的是同一份 `rendered*` 清单（工程自检第 24 组钉着）。
func checkHiddenOverlaysStayOutOfExport(white: URL, info: MediaInfo) async {
    for hidden in [false, true] {
        var state = TimelineState()
        state.mainClips = [EditClip(sourceURL: white, sourceDuration: 4, timelineStart: 0, info: info)]
        var text = TextOverlay(text: "Hi", timelineStart: 0, duration: 4)
        var shape = ShapeAnnotation(kind: .rectangle, timelineStart: 0, duration: 4)
        var filter = FilterClip(preset: .tealOrange, timelineStart: 0, duration: 4)
        text.isHidden = hidden
        shape.isHidden = hidden
        filter.isHidden = hidden
        state.textOverlays = [text]
        state.shapes = [shape]
        state.filters = [filter]
        let name = hidden ? "overlays-hidden" : "overlays-visible"
        let output = root.appendingPathComponent("\(name).mp4")
        guard let plan = try? await VideoEditExportGraph.plan(
            state: state, settings: VideoEncodeSettings(), subtitleStyle: BurnInStyle(name: "check"),
            subtitleFontURL: nil, output: output
        ) else {
            check(false, "\(name) 的 plan() 失败")
            continue
        }
        try? FileManager.default.removeItem(at: plan.workspace)
        let args = plan.arguments
        for (label, present) in [
            ("文字 PNG", args.contains { $0.hasPrefix("text0") }),
            ("形状 PNG", args.contains { $0.hasPrefix("shape0") }),
            ("lut3d 调色", args.contains { $0.contains("lut3d") })
        ] {
            if hidden {
                check(!present, "\(name)：藏起来的\(label)不许进导出图")
            } else {
                check(present, "\(name)（对照）：没藏的\(label)应当在导出图里")
            }
        }
    }
}
