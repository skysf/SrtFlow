import SwiftUI

/// 轨道配色：**一条轨一个颜色**，时间线上的块和轨道头的色条共用同一份。
///
/// 为什么不按「轨道种类」上色（改之前就是那样：主轨青、上层轨紫、音频轨蓝）：
/// 上层视频轨可以有好几条，同色的话，一眼看不出某个块属于哪一条轨 —— 而这
/// 恰恰是多轨剪辑里最常要回答的问题。
///
/// ## 两条硬约定
///
/// 1. **色号绑轨道身份，不绑行号。** 存在 `EditLane.colorIndex` 里（老工程没有
///    这个键，读盘时按当时的行序补一次）。绑行号的话，删掉中间一条轨，下面
///    所有轨的颜色会跟着整体平移一格，等于每次删轨都把用户的颜色记忆洗一遍。
/// 2. **视频轨和音频轨各占一段互不重叠的色相带。** 先让人分清「这是画面还是
///    声音」，再分清「第几条」。
enum TrackPalette {
    /// 主轨恒定占用视频色号 0。
    ///
    /// 主轨不是 `EditLane`，没有地方存 `colorIndex`；而「最底下那条轨永远是
    /// 这个颜色」本身就是可预期的，不值得为它单开一个可变字段。上层视频轨
    /// 分配色号时把 0 让出来（见 `assignMissingTrackColors`）。
    static let mainTrackColorIndex = 0

    /// 视频轨的色相（度）。
    ///
    /// **顺序是按「先分得最开」排的，不是按色相递增。** 常见工程只有两三条
    /// 视频轨，前几个色号必须一眼分得清；排成递增的话青(186°) 和蓝(205°) 会
    /// 挨在一起，在时间线那么小的色块上根本分不出来。
    private static let videoHues: [Double] = [186, 282, 232, 326, 205, 258]

    /// 音频轨的色相（度）。整段落在暖色区，与视频轨的冷色带不重叠。
    private static let audioHues: [Double] = [34, 124, 72, 8, 152]

    /// 时间线上剪辑块的填充色。
    static func clipFill(video index: Int) -> Color { color(videoHues, index, saturation: 0.55, brightness: 0.82, opacity: 0.42) }
    static func clipFill(audio index: Int) -> Color { color(audioHues, index, saturation: 0.55, brightness: 0.82, opacity: 0.42) }

    /// 轨道头的色条 / 选中描边：同色相，更实，供小面积使用。
    ///
    /// 空轨在时间线上一个块都没有，只有这条色条能告诉用户它是哪条轨 ——
    /// 所以色条不能省。
    static func accent(video index: Int) -> Color { color(videoHues, index, saturation: 0.72, brightness: 0.70, opacity: 1) }
    static func accent(audio index: Int) -> Color { color(audioHues, index, saturation: 0.72, brightness: 0.70, opacity: 1) }

    /// 文字块的固定色。**不跟轨道色表走** —— 文字不是一条轨，它是压在所有画面
    /// 之上的标注；给它一个轨道色会让人以为时间线上多了条视频轨。
    ///
    /// 饱和度压到很低（近中性），于是它既不和形状块（用户自选色，默认黄）撞，
    /// 也不和冷/暖两条轨道色带撞 —— 一眼就能看出"这一族不是轨道"。
    static let textBlock = Color(hue: 0.58, saturation: 0.14, brightness: 0.66)

    /// 色号超出色相表就回绕。回绕后会撞色，但要撞得上得先开到第 7 条视频轨，
    /// 与其为此把色相挤得更密（前几条反而更难分），不如让罕见情况去撞。
    private static func color(
        _ hues: [Double], _ index: Int, saturation: Double, brightness: Double, opacity: Double
    ) -> Color {
        let slot = hues.isEmpty ? 0 : ((index % hues.count) + hues.count) % hues.count
        let hue = hues.isEmpty ? 0 : hues[slot]
        return Color(hue: hue / 360, saturation: saturation, brightness: brightness)
            .opacity(opacity)
    }
}

extension TimelineState {
    /// 这条轨的色号。轨道头和块共用它，保证同一条轨上下一致。
    ///
    /// 轨还没补到号（刚 append 出来、`assignMissingTrackColors` 还没跑）时退回
    /// 行号，只是为了不让界面短暂没颜色；真正的稳定值来自 `colorIndex`。
    func trackColorIndex(for slot: TrackSlot) -> Int {
        switch slot {
        case .main:
            return TrackPalette.mainTrackColorIndex
        case .overlay(let index):
            guard overlayTracks.indices.contains(index) else { return 0 }
            return overlayTracks[index].colorIndex ?? (index + 1)
        case .audio(let index):
            guard audioTracks.indices.contains(index) else { return 0 }
            return audioTracks[index].colorIndex ?? index
        }
    }

    /// 时间线上这条轨的块该填什么色。
    func trackClipFill(for slot: TrackSlot) -> Color {
        let index = trackColorIndex(for: slot)
        return slot.isAudio ? TrackPalette.clipFill(audio: index) : TrackPalette.clipFill(video: index)
    }

    /// 轨道头色条该用什么色。
    func trackAccent(for slot: TrackSlot) -> Color {
        let index = trackColorIndex(for: slot)
        return slot.isAudio ? TrackPalette.accent(audio: index) : TrackPalette.accent(video: index)
    }

    /// 给还没有色号的轨补号：同类里取**最小的未占用号**。
    ///
    /// 幂等 —— 已经有号的轨一个都不动，所以可以挂在每次状态提交后面反复跑。
    /// 「最小未占用」而不是「顺序递增」：删掉中间一条轨再新开一条，新轨会
    /// 捡回刚空出来的那个颜色，而不是一路往后漂到色相表尽头去撞色。
    mutating func assignMissingTrackColors() {
        // 上层视频轨与主轨同用一张色相表，所以要把主轨占的号让出来。
        assign(&overlayTracks, reserved: [TrackPalette.mainTrackColorIndex])
        assign(&audioTracks, reserved: [])
    }

    private func assign(_ lanes: inout [EditLane], reserved: Set<Int>) {
        var used = reserved
        for lane in lanes { if let index = lane.colorIndex { used.insert(index) } }
        for position in lanes.indices where lanes[position].colorIndex == nil {
            var candidate = 0
            while used.contains(candidate) { candidate += 1 }
            lanes[position].colorIndex = candidate
            used.insert(candidate)
        }
    }
}
