import Foundation

// 字幕分段的参数：一条字幕多宽、多长、显示多久、两条之间留多少、读多快。
//
// 2026-09-26 起按主流字幕规范定（用户：「用户体验最好的方式来，符合主流字幕的样式」）：
// Netflix 英文 / 简体中文字幕规范 —— 每行 42 个字符（空格也算）/ 16 个字（半角算半个），
// 最短 5/6 秒、最长 7 秒，两条之间 2 帧、不到半秒的空档接上，英文 20 字符/秒、中文 9 字/秒；
// 外加我们自己定的「按逗号拆出来的一条至少 1 秒」。每一条的出处和理由见
// docs/architecture/subtitle-generation-style.md。
//
// 管什么：参数本身，以及生成时按转写语言、画面宽度、工程帧率选哪一套（`generation(...)`）。
// 全部按**时间线时长**评估（同一素材在不同速度的片段上分段不同，是合同行为）。
// 不管什么：在哪断（`SubtitleBreaks`）、显示时间怎么排（`SubtitleCueTiming`）。

public struct SubtitleSegmentationConfig: Hashable, Sendable {
    /// 最多几行。生成的字幕一律单行（2026-08-09 产品决定），放不下就拆成下一条。
    public var maxLineCount: Int
    /// 每行最多几个字，按 `SubtitleLineMeasure.units` 数（全角 1、半角 0.5）：英文 42 个字符 = 21，中文 16。
    public var maxLineUnits: Double
    /// 每行最多占几个字号宽（`SubtitleLineMeasure.ems`）：按画面宽度和字号算的「放得下」，竖屏更窄。
    /// 无穷大 = 不按画面封（自检、拿不到画面信息时）。
    public var maxLineEms: Double
    /// 一条最短显示多久（Netflix：5/6 秒），往后有空档就借。
    public var minCueDuration: Double
    /// 一条最长多久（Netflix：7 秒），超过就拆。
    public var maxCueDuration: Double
    /// 阅读速度上限，按 units 每秒数：英文 20 字符/秒 = 10，中文 9 字/秒。超了只告警，不假装满足。
    public var maxUnitsPerSecond: Double
    /// 词间停顿超过它就断句（时间线秒）。
    public var pauseThreshold: Double
    /// 按逗号拆出来的一条至少多长；不够（或只有一个词）就并到旁边那条。
    public var minClauseDuration: Double
    /// 一帧多长（工程帧率，生产上来自 `TimelineState.frameRate`）。两条字幕之间留 `gapFrames` 帧，
    /// 观众才看得出换了一条。
    public var frameDuration: Double
    public var gapFrames: Int
    /// 两条之间的空档不到它，就把前一条延到只剩 `gapFrames` 帧，不让字幕闪一下。
    public var chainThreshold: Double
    /// 说完之后多停多久（后面没有紧跟着的下一条时）。
    public var trailingHold: Double

    /// 参数集版本：进 GenerationSnapshot，缓存 / 重现用。
    /// v2：默认单行（2026-08-09）。v3（2026-09-26）：按主流规范重定 —— 去标点、按逗号拆句、
    /// 每行按字数（全角 1 半角 0.5）和画面宽度封顶、最短 5/6 秒、两条之间 2 帧、中英分档。
    public static let version = 3

    public init(
        maxLineCount: Int = 1,
        maxLineUnits: Double = 21,
        maxLineEms: Double = .infinity,
        minCueDuration: Double = 5.0 / 6.0,
        maxCueDuration: Double = 7,
        maxUnitsPerSecond: Double = 10,
        pauseThreshold: Double = 0.6,
        minClauseDuration: Double = 1,
        frameDuration: Double = ProjectFrameRate.fallback.secondsPerFrame,
        gapFrames: Int = 2,
        chainThreshold: Double = 0.5,
        trailingHold: Double = 0.5
    ) {
        self.maxLineCount = maxLineCount
        self.maxLineUnits = maxLineUnits
        self.maxLineEms = maxLineEms
        self.minCueDuration = minCueDuration
        self.maxCueDuration = maxCueDuration
        self.maxUnitsPerSecond = maxUnitsPerSecond
        self.pauseThreshold = pauseThreshold
        self.minClauseDuration = minClauseDuration
        self.frameDuration = frameDuration
        self.gapFrames = gapFrames
        self.chainThreshold = chainThreshold
        self.trailingHold = trailingHold
    }

    /// 两条字幕之间留的空（秒）。
    public var gap: Double { Double(gapFrames) * frameDuration }

    /// 以全角字为主的语言：每行 16 个字、9 字/秒（Netflix 简体中文规范）。
    /// 日文、韩文没有单独核对过，先归这一档。
    static let fullWidthLanguages: Set<String> = ["zh", "yue", "wuu", "ja", "ko"]

    /// 生成时用的一套。
    /// - Parameters:
    ///   - languageCode: 转写实际用的语言（"en"、"zh"…），按它选每行字数和阅读速度；nil 按英文那一档。
    ///   - frameDuration: 工程一帧多长（两条之间留 2 帧）。
    ///   - maxLineEms: 一行在画面上放得下几个字号宽（App 那边按字幕样式和画面宽度算）。
    public static func generation(
        languageCode: String?, frameDuration: Double, maxLineEms: Double
    ) -> SubtitleSegmentationConfig {
        var config = SubtitleSegmentationConfig(maxLineEms: maxLineEms, frameDuration: frameDuration)
        if let languageCode, fullWidthLanguages.contains(languageCode) {
            config.maxLineUnits = 16
            config.maxUnitsPerSecond = 9
        }
        return config
    }
}
