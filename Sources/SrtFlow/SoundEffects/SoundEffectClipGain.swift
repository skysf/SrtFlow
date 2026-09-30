import Foundation

// MARK: - 音效放上时间线时段的默认音量（纯值，一处）
//
// 管什么：合成的音效和音效库里的素材都是峰值 −1 dBFS 的，原样放会盖过人声，默认压 −8 dB；AI 用 `volume_db` 改，用户用检查器改。
// 合成器（AISoundEffectRequest）、音效库的条目（AudioLibraryItem.defaultClipGainDB）都从这里拿，不各写一个数。
// 不管什么：文件本身的电平（SoundEffectSynth：峰值 −1 dBFS、响度 ≤ −9 LUFS；音效库：sfx_normalize.py 峰值归一）。

enum SoundEffectClipGain {
    static let defaultDB = -8.0
}
