// SrtFlowKokoro —— 从 speech-swift（https://github.com/soniqo/speech-swift，Apache License 2.0，Copyright 2025 Ivan Digital）
// 的 KokoroTTS 模块搬过来的代码，为 SrtFlow 改过。授权全文与署名见 Sources/SrtFlow/Resources/THIRD-PARTY-NOTICES.md（随 App 分发）。
// 这个文件：Kokoro-82M 的几个固定参数。原样搬来。
// 为什么搬代码而不是加依赖：docs/plans/2026-09-27-mcp.md 第 44 条（App 不加第三方依赖，钉版本自己维护）。

import Foundation

/// Configuration for Kokoro-82M TTS model.
public struct KokoroConfig: Codable, Sendable {
    /// Output audio sample rate in Hz.
    public let sampleRate: Int
    /// Maximum phoneme input length (E2E model uses fixed 128).
    public let maxPhonemeLength: Int
    /// Style embedding dimension (ref_s input to CoreML model).
    public let styleDim: Int
    /// Supported languages.
    public let languages: [String]

    public init(
        sampleRate: Int = 24000,
        maxPhonemeLength: Int = 128,
        styleDim: Int = 256,
        languages: [String] = ["en", "fr", "es", "ja", "zh", "hi", "pt", "it"]
    ) {
        self.sampleRate = sampleRate
        self.maxPhonemeLength = maxPhonemeLength
        self.styleDim = styleDim
        self.languages = languages
    }

    /// Default configuration matching Kokoro-82M.
    public static let `default` = KokoroConfig()
}
