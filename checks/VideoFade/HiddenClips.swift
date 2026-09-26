import Foundation

// 藏起来的上层段不进成片：真导出、抽帧量像素。
// 管什么：上层视频轨上「整轨藏起来」和「单段按 V 藏起来」在 ffmpeg 导出里的样子。
// 不管什么：预览那条管线（`scripts/check-preview-composition.sh` 钉着）、主轨的隐藏（main.swift 之外的
// 工程自检和预览取帧钉着）。
//
// 2026-09-26 案例 docs/bugfixes/2026-09-26-hidden-upper-clip-still-exported.md：导出图里叠上层轨的
// 那一圈（连同预渲染那一圈）只滤了藏起来的轨、没滤藏起来的段 —— 预览里没了，成片里画面照旧在
// （声音走预览那份混音，早就滤掉了，所以只漏画面）。以前的守卫只扫「文件里出现过
// `ClipVisibility.visible(`」，主轨那一行就满足了。

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
