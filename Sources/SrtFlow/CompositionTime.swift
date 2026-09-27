import AVFoundation

// MARK: - 预览合成里的时间：秒怎么换成格子、素材怎么往合成轨上接
//
// 管什么：VideoEditCompositionBuilder 往合成轨上接素材、空白、定格时守的三条规矩。
// 1. **秒 → 1/600 秒的格子，四舍五入**。`CMTime(seconds:preferredTimescale:)` 向零截断：
//    5.3 + 1.4 在浮点里是 6.699999999999999，截断落在第 4019 格，写成 6.7 的下一段却在 4020 ——
//    相邻的两个时间差出一格。
// 2. **只往合成轨真正的末尾后面接**，不信 Double 游标。`insertTimeRange` / `insertEmptyTimeRange`
//    是「插入」：落点早于末尾，就把已经插好的内容往后挤。
// 3. **合成完把每条合成轨裁到时间线的总长**。视频合成的指令只铺到总长，哪条轨多出一格，
//    合成就被判无效，预览整个黑屏（标题这类叠层照样画在上面）。
//
// 2026-09-27 实测：音效轨上的空白从 4019 插进去，切下前一段音效的最后一格、一路挤到全片最后，
// 音轨比画面长 1/600 秒 → 黑屏；正式版一样（docs/bugfixes/2026-09-27-preview-black-after-audio-tick-pushed-past-end.md）。
// 不管什么：摆放、渐变、转场这些几何（builder 自己）；声音的音量斜坡（AudioMixBuilder）。

enum CompositionTime {
    static let timescale: CMTimeScale = 600

    /// 秒 → 最近的格子（负数当 0）。
    static func ticks(_ seconds: Double) -> CMTime {
        CMTime(value: CMTimeValue((max(0, seconds) * Double(timescale)).rounded()), timescale: timescale)
    }

    /// 合成轨现在的末尾：看它真有的片段，不看算出来的游标。
    static func end(of track: AVMutableCompositionTrack) -> CMTime {
        track.segments.last?.timeMapping.target.end ?? .zero
    }

    /// 下一段接在哪：想要的落点，但不早于合成轨现在的末尾（早了就会把前面的内容往后挤）。
    static func appendPoint(_ wanted: CMTime, on track: AVMutableCompositionTrack) -> CMTime {
        CMTimeMaximum(wanted, end(of: track))
    }

    /// 从合成轨真正的末尾补空白，补到 `wanted`；已经到了就不补。
    static func pad(_ track: AVMutableCompositionTrack, to wanted: CMTime) {
        let end = end(of: track)
        if wanted > end { track.insertEmptyTimeRange(CMTimeRange(start: end, end: wanted)) }
    }

    /// 每条合成轨超出 `length` 的部分剪掉：时间线上没有东西能落在总长之后，多出来的只可能是换算的零头。
    static func trim(_ composition: AVMutableComposition, to length: CMTime) {
        for track in composition.tracks where end(of: track) > length {
            track.removeTimeRange(CMTimeRange(start: length, end: end(of: track)))
        }
    }
}
