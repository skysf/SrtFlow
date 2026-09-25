import AVFoundation
import Foundation

// MARK: - 6b. 正在播的预览换上的那份 mix，和成片是同一份
//
// 预览换 mix 的三个入口（`scheduleRebuild` 重建、`refreshAudioMix` 快路径、`previewAudioLive`
// 拖动试听）都拿**用户那一份**状态调 `makeAudioMix`。2026-09-24 以前它照着那份没展开的几何铺
// 斜坡，而插进合成里的是 `expandingTransitionHandles` 展开过的段 —— 转场接缝上预览的声音掉下去
// 一截，零余料的缝（首尾帧定格）中间几乎静音；成片（读 build() 顺手产出的那份 mix）却是对的。
// 上面几组读的都是 `built.audioMix`，走不到那三个入口，所以一直是绿的
// （docs/bugfixes/2026-09-24-preview-mix-ignores-transition-expansion.md）。
//
// 这一组照生产入口的样子，用用户状态 + build 出来的 plan 重新调一次 `makeAudioMix`，
// 逐窗对 `built.audioMix`。两种要展开的缝都要有：借余料的、零余料要定格补足的。
// （第 6 组那个「已相叠」的缝用不着展开，所以它照不出这个问题。）

/// 两段 PCM 逐窗（100ms RMS）一致：差不过 `tolerance` dB。太安静的窗口（两边都低于 −50 dB）
/// 不比 —— 那里 dB 值只是噪声。
func checkSameEnvelope(
    _ actual: [Float], _ expected: [Float], from: Double, to: Double,
    tolerance: Double = 0.5, _ label: String
) {
    var worst = 0.0
    var worstAt = from
    var compared = 0
    var time = from
    while time + 0.1 <= to {
        let a = decibels(rms(actual, from: time, to: time + 0.1))
        let b = decibels(rms(expected, from: time, to: time + 0.1))
        if max(a, b) > -50 {
            compared += 1
            if abs(a - b) > worst {
                worst = abs(a - b)
                worstAt = time
            }
        }
        time += 0.1
    }
    check(compared > 5, "\(label)：有声音的窗口太少（\(compared)），比不出东西")
    check(worst <= tolerance,
          String(format: "%@：最大相差 %.2f dB（在 %.1fs 处），允许 %.2f dB", label, worst, worstAt, tolerance))
}

func decibels(_ linear: Double) -> Double {
    20 * log10(max(linear, 1e-9))
}

func checkLiveMixFollowsExpandedSeams(videoSource: URL) async {
    // 借余料：第一段后面、第二段前面各裁掉 1 秒，缝上 1 秒的叠化从两边借。
    var tail = EditClip(sourceURL: videoSource, sourceDuration: 3, timelineStart: 0, info: videoInfo)
    tail.transitionAfter = .crossFade
    tail.transitionDuration = 1
    let head = EditClip(
        sourceURL: videoSource, sourceStart: 1, sourceDuration: 3, timelineStart: 3, info: videoInfo
    )
    // 零余料：两段都没裁，缝上的叠化只能靠首尾帧定格补出来。
    var whole = EditClip(sourceURL: videoSource, sourceDuration: 4, timelineStart: 0, info: videoInfo)
    whole.transitionAfter = .crossFade
    whole.transitionDuration = 1
    let next = EditClip(sourceURL: videoSource, sourceDuration: 4, timelineStart: 4, info: videoInfo)

    // 每种缝的**绝对**期望（相对远离接缝处的满音量，单位 dB）。光拿两份 mix 互相比不够：
    // 2026-09-24 反向验证时把修复撤掉，build() 自己那份也跟着照没展开的几何铺，两份一起错、
    // 互相比照样一致 —— 守卫没红。所以每一窗还要对「这条缝本来该是多响」：
    // - 借余料：同一条正弦、同相位，1 秒线性交叉淡变的两半加起来一直是满音量（±1 dB）；
    // - 零余料：定格那两截没有声音，出场段在缝上只剩一半增益、进场段也是 —— 最低掉到
    //   −6 dB（修复前是 −30 dB 上下）。
    let cases: [(String, [EditClip], Double, ClosedRange<Double>)] = [
        ("借余料的叠化", [tail, head], 3.0, -1...1),
        ("零余料的叠化（定格补足）", [whole, next], 4.0, -7...1),
    ]
    for (label, clips, seam, allowed) in cases {
        var state = TimelineState()
        state.frameRate = .fps30
        state.canvasRatio = .wide16x9
        state.mainClips = clips
        guard let built = await VideoEditCompositionBuilder.build(from: state) else {
            check(false, "\(label)：预览合成没建起来")
            continue
        }
        // 生产入口的样子：用户状态 + 这次合成的 plan。
        let live = VideoEditCompositionBuilder.makeAudioMix(state: state, plan: built.audioPlan)
        let livePCM = await previewPCM(built.composition, mix: live)
        let builtPCM = await previewPCM(built)
        checkSameEnvelope(livePCM, builtPCM, from: seam - 1, to: seam + 1, tolerance: 0.1,
                          "\(label) · 正在播的预览 vs 成片那份 mix")

        let full = decibels(rms(livePCM, from: 1.0, to: 1.1))
        check(full > -40, "\(label)：远离接缝处要有声音（\(full) dB）")
        var time = seam - 0.5
        while time + 0.1 <= seam + 0.5 {
            let level = decibels(rms(livePCM, from: time, to: time + 0.1)) - full
            check(allowed.contains(level),
                  String(format: "%@：接缝附近 %.1fs 处比满音量差 %.1f dB，应在 %.0f…%.0f dB —— "
                         + "音量斜坡没照展开过的几何铺，声音在缝上掉下去了",
                         label, time, level, allowed.lowerBound, allowed.upperBound))
            time += 0.1
        }
    }
}
