import Foundation

// 播放跟随的纯值自检（PlayheadFollow，Sources/SrtFlow/VideoEditTimelinePlayheadFollow.swift）。
// 2026-10-01 用户拍板：播放时轨道区域停在哪就停在哪 —— 跟随是开关、默认关；开着时照旧翻页：
// 播放头到视口右边 80pt / 左边 40pt 以内才推，推到视口左侧 15%。由 main.swift 调。

func runPlayheadFollowChecks() {
    typealias Follow = PlayheadFollow
    func target(_ x: Double, offset: Double = 0, width: Double = 800, enabled: Bool = true) -> Double? {
        Follow.scrollTarget(playheadX: x, offsetX: offset, viewportWidth: width, enabled: enabled)
    }

    // 关着：播放头在视口里、贴边、早就滚出去了，一律不推。
    for x in [0.0, 39, 400, 720, 721, 3000, -50] {
        check(target(x, enabled: false) == nil, "开关关着时播放头在 \(x) 也不推（停在哪就停在哪）")
    }
    for offset in [0.0, 500, 12_000] {
        check(target(offset + 10_000, offset: offset, enabled: false) == nil, "关着时滚过 \(offset) 之后播放头远在右边也不推")
    }

    // 开着：视口 800、没滚过 —— 右边 80 以内、左边 40 以内才推。
    check(target(400) == nil, "播放头在视口中间不推（每帧居中会看得人晕）")
    check(target(720) == nil, "正好压在右边 80 那条线上还不推（要越过才推）")
    checkClose(target(721), 721 - 800 * 0.15, "越过右边那条线：推到播放头落在视口左侧 15% 处")
    check(target(40) == nil, "正好压在左边 40 那条线上不推")
    checkClose(target(39), 39 - 120, "越过左边那条线：同样推到 15% 处（算出来是负的，交给滚动几何夹到 0）")
    if let t = target(721) { checkClose((721 - t) / 800, Follow.landing, "推完播放头在视口的几成处 = landing") }

    // 滚过一段之后，边线跟着滚动量走。
    check(target(1219, offset: 500) == nil, "滚到 500 之后，1219 还在视口里（右边线 1220）")
    checkClose(target(1221, offset: 500), 1221 - 120, "滚到 500 之后越过 1220 才推")
    check(target(541, offset: 500) == nil, "滚到 500 之后 541 还在视口里（左边线 540）")
    checkClose(target(539, offset: 500), 539 - 120, "滚到 500 之后退到 540 以左才推")

    // 视口窄到放不下边距：不推（没地方可留）。
    check(target(5000, width: 80) == nil, "视口只有 80 宽时不推")
    check(target(5000, width: 81) != nil, "视口 81 宽就按规矩推")
    check(Follow.leftMargin == 40 && Follow.rightMargin == 80 && Follow.landing == 0.15, "边距和落点是写进文档的那三个数")
}
