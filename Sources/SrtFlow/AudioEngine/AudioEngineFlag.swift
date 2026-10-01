import Foundation

// MARK: - 预览的声音走不走引擎（迁移期的开关）
//
// 管什么：一个布尔。`SRTFLOW_AUDIO_ENGINE=1`（环境变量，冒烟和自检用）或 `defaults write com.srtflow.SrtFlow audioEngine -bool YES`
// （测试版用）就开；默认关 —— 正式版的声音照旧走 AVPlayer 的合成，直到 PR3 删旧路。
// 进程启动时定下，之后不变（和 PerfCounters.isEnabled 一个做法：中途切换两条路会各留一半状态）。
// 方案：docs/plans/2026-10-01-audio-engine.md 第七节。

enum AudioEngineFlag {
    static let environmentKey = "SRTFLOW_AUDIO_ENGINE"
    static let defaultsKey = "audioEngine"

    static let isEnabled: Bool = {
        if let value = ProcessInfo.processInfo.environment[environmentKey] {
            return !value.isEmpty && value != "0"
        }
        return UserDefaults.standard.bool(forKey: defaultsKey)
    }()
}
