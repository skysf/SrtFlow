import AVFoundation
import Foundation

// MARK: - 视频合成的切片表：边界先落到格子上，指令按构造首尾相接
//
// 管什么：把视频合成的切片边界（时间线秒，Double：段的起止、渐变的起止和半程、关键帧、推移 / 擦除的窗口……）
// 变成一串**首尾相接**的 1/600 秒格子区间，指令表照它铺。秒换格子用的是和插段同一个截断（`CompositionTime.tick`）。
//
// 为什么要先落到格子上再去重：以前按秒去重（两个边界差不到 0.5 毫秒，中间那片不切），可两个边界各自截断之后
// 可能落在**相邻的两格**上 —— 前一片收在第 11975 格、后一片从第 11976 格起，指令表空出一格，整个视频合成就被
// 判无效，预览从头黑到尾（标题这类叠层照样画在上面）。AI 按报出来的三位小数放段（19.96）、而前一段真正收在
// 19.9598，或者最后一段画面收在 32.2097 而音乐收在 32.21，都会撞上；关键帧和转场只是多添了几个挨得近的边界
// （docs/bugfixes/2026-09-29-preview-black-slice-boundaries-straddle-a-tick.md）。
//
// 规矩：
// 1. 同一格里只留**最早**的那个边界，求值就用它（关键帧、渐变的半程都是精确的折点，别拿格子换回来的秒去求值）。
// 2. 相邻两格之间就是一片：片的区间是格子，求值的起止是两头那两个边界的秒。
// 3. 第一片从第 0 格起、最后一片收在总长那一格上（`CompositionTime.trim` 把合成轨也裁到同一格）。
//
// 不管什么：片里谁可见、变换 / 裁切 / 透明度怎么算（VideoEditCompositionBuilder 自己）。

/// 一片：合成里的格子区间 + 求值用的时间线秒。
struct CompositionSlice: Equatable {
    var range: CMTimeRange
    /// 这一格里最早的边界（时间线秒）；片内一切都线性，两端取值就是精确重建。
    var start: Double
    /// 下一片的 `start`。
    var end: Double
}

enum CompositionSlices {
    /// 把边界铺成首尾相接的切片表。`totalDuration` 之外的边界不要；起点和总长自己一定在表里。
    static func make(boundaries: Set<Double>, totalDuration: Double) -> [CompositionSlice] {
        var earliest: [Int64: Double] = [0: 0]
        for boundary in boundaries where boundary > 0 && boundary <= totalDuration {
            let tick = CompositionTime.tick(boundary).value
            if let existing = earliest[tick], existing <= boundary { continue }
            earliest[tick] = boundary
        }
        let last = CompositionTime.tick(totalDuration).value
        if earliest[last] == nil { earliest[last] = totalDuration }
        let ticks = earliest.keys.sorted()
        return zip(ticks, ticks.dropFirst()).map { tick, next in
            CompositionSlice(
                range: CMTimeRange(
                    start: CMTime(value: tick, timescale: CompositionTime.timescale),
                    end: CMTime(value: next, timescale: CompositionTime.timescale)
                ),
                start: earliest[tick] ?? 0,
                end: earliest[next] ?? totalDuration
            )
        }
    }
}
