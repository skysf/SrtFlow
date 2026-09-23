import AVFoundation

// MARK: - 预览合成的音轨：一条合成音轨只装一种源音频格式
//
// 电平表在每条合成音轨上挂一个 `MTAudioProcessingTap`（VideoEditAudioMeter.swift）。同一条
// 合成音轨上前后两段的**源音频格式**不一样时 —— 采样率、声道数、编码任何一样，比如 48kHz 立体声
// 的音效后面接 44.1kHz 单声道的配音，或者 mp3 后面接 mp4 里的 AAC —— AVFoundation 会把 tap
// 重新 prepare 一遍，之后**再也不调它**：
//
// - 那条合成音轨从那儿起没有声音（播放器提前几秒读，所以比换格式的地方还早就断了）；
// - 从换了格式之后的地方起播，播放器干脆不走：时间停在原地，状态却还是「在播」。
//
// 离线的 AVAssetReaderAudioMixOutput 一样。只差编码参数（同是 AAC、码率不同）不算换格式，
// 变速段也不算。2026-09-23 实测，案例
// docs/bugfixes/2026-09-23-meter-tap-dies-on-audio-format-change.md。
//
// 所以一条时间线轨遇到新格式就另开一条合成音轨，同格式的段继续排在原来那条上。电平表按时间线轨
// 归并（几条合成轨按绝对位置相加，和主轨 A/B 同一个办法），表上看不出分了几条；音量斜坡各条
// 合成轨各铺各的，「提前钉音量」钉在同一条合成轨上一段的结尾，分出来的轨之间全是空档，照样成立。

/// 按「时间线上的哪条轨 × 源音频格式」发放合成音轨。一次合成用一个，用完即弃。
final class CompositionAudioTracks {
    /// 时间线上的哪条轨。主轨按 A/B 槽分：转场的两段要在不同的合成轨上叠着。
    enum Owner: Hashable {
        case main(slot: Int)
        case overlay(Int)
        case lane(UUID)
    }

    /// 一条合成音轨，带着它的插入游标（`insert` 只会往后插）。
    final class Slot {
        let track: AVMutableCompositionTrack
        fileprivate let format: CMFormatDescription?
        var cursor = 0.0

        fileprivate init(track: AVMutableCompositionTrack, format: CMFormatDescription?) {
            self.track = track
            self.format = format
        }
    }

    private let composition: AVMutableComposition
    private var slots: [Owner: [Slot]] = [:]

    init(composition: AVMutableComposition) {
        self.composition = composition
    }

    /// `owner` 这条轨上装 `source` 这种格式的合成音轨；还没有就新开一条。
    func slot(for owner: Owner, source: AVAssetTrack) async -> Slot? {
        let format = try? await source.load(.formatDescriptions).first
        if let existing = slots[owner]?.first(where: { Self.sameStream($0.format, format) }) {
            return existing
        }
        guard let track = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { return nil }
        let slot = Slot(track: track, format: format)
        slots[owner, default: []].append(slot)
        return slot
    }

    /// 两段算不算同一种格式：比流格式（编码、采样率、声道数……）和声道布局，**不比**编码器
    /// 参数（magic cookie）—— 实测只差码率的两个 AAC 挂着 tap 也能接着播，再细分就是白开轨。
    static func sameStream(_ a: CMFormatDescription?, _ b: CMFormatDescription?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return CMAudioFormatDescriptionEqual(
            a,
            otherFormatDescription: b,
            equalityMask: kCMAudioFormatDescriptionMask_StreamBasicDescription
                | kCMAudioFormatDescriptionMask_ChannelLayout,
            equalityMaskOut: nil
        )
    }
}
