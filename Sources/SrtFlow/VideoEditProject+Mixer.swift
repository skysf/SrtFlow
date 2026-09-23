import Foundation

// MARK: - 推子的写入口
//
// 轨道头推子和总推子：拖动中只「当场听得见」（`previewAudioLive`，不写 state），
// 松手落一次（一步撤销、只换 audioMix 不闪画面）。夹紧只在 `AudioGain.clampedLinear`
// 一处。合同见 docs/architecture/audio-mixer.md。

extension VideoEditProject {
    func setTrackVolume(_ linear: Double, for slot: TrackSlot) {
        perform { $0.setTrackVolume(linear, for: slot) }
    }

    func setMasterVolume(_ linear: Double) {
        perform { $0.masterVolume = AudioGain.clampedLinear(linear) }
    }

    func previewTrackVolume(_ linear: Double, for slot: TrackSlot) {
        previewAudioLive { $0.setTrackVolume(linear, for: slot) }
    }

    func previewMasterVolume(_ linear: Double) {
        previewAudioLive { $0.masterVolume = AudioGain.clampedLinear(linear) }
    }
}
