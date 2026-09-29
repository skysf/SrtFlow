import AVFoundation

// MARK: - 预览合成往合成轨上接东西：只从真正的末尾往后接，合成完裁到时间线总长
//
// 管什么：VideoEditCompositionBuilder（和声音场景的余音载体）往合成轨上接素材、空白、定格时守的两条规矩。
// 1. **只往合成轨真正的末尾后面接**，不信 Double 算出来的游标。`insertTimeRange` / `insertEmptyTimeRange`
//    是「插入」：落点早于末尾，就把已经插好的内容往后挤，而且不报错。秒换成 1/600 秒的格子用的是
//    `CMTime(seconds:)`，它**截断**：5.3 + 1.4 在浮点里是 6.699999999999999，截断落在第 4019 格，
//    而上一段明明插到了 4020 —— 从 4019 补空白，就切下了上一段的最后一格。
// 2. **合成完把每条合成轨裁到时间线总长**。视频合成的指令只铺到总长，哪条轨多出一格，合成就被判无效，
//    预览整个黑屏（标题这类叠层照样画在上面）。
//
// 2026-09-27 实测：音效轨上被切下的那一格一路挤到全片最后，音轨比画面长 1/600 秒 → 黑屏；正式版一样
// （docs/bugfixes/2026-09-27-preview-black-after-audio-tick-pushed-past-end.md）。
//
// **换格子仍然截断，别改成四舍五入。** 截断保证从素材里取的范围不会超出素材本身。第一版修复把换算
// 改成了四舍五入，CI（macOS 15）上声音渐变自检读混音卡死 30 分钟，本机（macOS 26）复现不出来、
// 也没找到确切原因；上面两条规矩已经足够修黑屏，就不去动换算。
// 不管什么：摆放、渐变、转场这些几何（builder 自己）；声音的音量斜坡（AudioMixBuilder）。

enum CompositionTime {
    /// 合成轨现在的末尾：看它真有的片段，不看算出来的游标。
    static func end(of track: AVMutableCompositionTrack) -> CMTime {
        track.segments.last?.timeMapping.target.end ?? .zero
    }

    /// 一格：前后两段首尾相接、各自截断出来差这么多，算零头，不算空档（和以前「差不到 0.5 毫秒不补」同一个意思）。
    static let oneTick = CMTime(value: 1, timescale: 600)

    /// 下一段接在哪：不早于合成轨现在的末尾（早了会把前面的内容往后挤）；只比末尾晚一格也接在末尾上，
    /// 首尾相接的两段之间不留一格的空段。
    static func appendPoint(_ wanted: CMTime, on track: AVMutableCompositionTrack) -> CMTime {
        let end = end(of: track)
        return wanted > end + oneTick ? wanted : end
    }

    /// 从合成轨真正的末尾补空白，补到 `wanted`；差不到一格不补（同上）。
    static func pad(_ track: AVMutableCompositionTrack, to wanted: CMTime) {
        let end = end(of: track)
        if wanted > end + oneTick { track.insertEmptyTimeRange(CMTimeRange(start: end, end: wanted)) }
    }

    /// 每条合成轨超出 `length` 的部分剪掉：时间线上没有东西能落在总长之后，多出来的只可能是换算的零头。
    static func trim(_ composition: AVMutableComposition, to length: CMTime) {
        for track in composition.tracks where end(of: track) > length {
            track.removeTimeRange(CMTimeRange(start: length, end: end(of: track)))
        }
    }
}
