import Foundation

// MARK: - 预览的声音走不走引擎（迁移期的开关）
//
// 管什么：一个布尔。**默认开**（2026-10-01 PR3a 起：预览和成片都走引擎）；`SRTFLOW_AUDIO_ENGINE=0`（环境变量）或
// `defaults write com.srtflow.SrtFlow audioEngine -bool NO` 关回 AVPlayer 的合成那条路 —— 只留到 PR3b 删旧路。
// 进程启动时定下，之后不变（和 PerfCounters.isEnabled 一个做法：中途切换两条路会各留一半状态）。
// 方案：docs/plans/2026-10-01-audio-engine.md 第七节。

enum AudioEngineFlag {
    static let environmentKey = "SRTFLOW_AUDIO_ENGINE"
    static let defaultsKey = "audioEngine"

    static let isEnabled: Bool = {
        if let value = ProcessInfo.processInfo.environment[environmentKey] {
            return !value.isEmpty && value != "0"
        }
        return (UserDefaults.standard.object(forKey: defaultsKey) as? Bool) ?? true
    }()
}
