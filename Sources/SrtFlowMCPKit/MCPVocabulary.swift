import Foundation

// MARK: - 工具参数里的「选项词表」
//
// 管什么：转场、滤镜、文字动画、画面比例这些枚举参数，AI 能填哪几个值。
// 为什么在这儿抄一份：小程序不链接 App 的代码，拿不到 `ClipTransition` 这些类型；
// 而工具清单必须由小程序给出（Claude 一启动就要清单，不能为此把 SrtFlow 拉起来）。
// **抄的就会漂**，所以 `scripts/check-mcp.sh` 把这里的每一张表和 App 里对应类型的
// `allCases` 逐项对账，对不上就红。

public enum MCPVocabulary {
    /// = `ClipTransition.allCases` 的原始值。
    public static let transitions = [
        "none", "crossFade", "blackFade", "whiteFade",
        "pushLeft", "pushRight", "pushUp", "pushDown",
        "wipeLeft", "wipeRight", "wipeUp", "wipeDown"
    ]

    /// = `FilterPreset.allCases` 的原始值，后面是给 AI 挑的时候看的一句话。
    public static let filterPresets: [(id: String, look: String)] = [
        ("tealOrange", "blockbuster teal shadows, warm skin"),
        ("coldIron", "cold, desaturated, hard contrast, industrial"),
        ("warmSun", "warm golden everyday light"),
        ("flatGrey", "flat, low-saturation documentary look"),
        ("nightGold", "night scenes with amber highlights, deep blacks"),
        ("fadedFilm", "old faded film, lifted blacks"),
        ("coldWhite", "bright, clean, cool whites (products, interiors)"),
        ("mistBlue", "misty early-morning blue, low contrast"),
        ("inkShadow", "black and white with hard contrast"),
        ("neon", "cyberpunk magenta and cyan, full saturation")
    ]

    /// = `TextAnimationKind.allCases` 的原始值。
    public static let textAnimations = [
        "none", "fade", "rise", "pop", "typewriter", "cascade", "blur", "focus", "wipe", "strokeDraw"
    ]

    /// = `TextEmphasisKind.allCases` 的原始值（文字在画面上期间一直循环的强调）。
    public static let textEmphasis = ["none", "breathe"]

    /// = `NumberRollStyle.allCases` 的原始值（数字滚动：整体数上去 / 每一位各自转的老虎机）。
    public static let numberStyles = ["count", "odometer"]

    /// = `AIVoiceRole.all` 的名字：配音的角色（配方卡里写的是角色；装了 SrtFlow 自己的声音用对应的 Kokoro 音色，没装按这台 Mac
    /// 的声音挑；方案第 16、43、49 条）。
    public static let voiceRoles = [
        "zh_female_lively", "zh_female_warm", "zh_male",
        "en_female_lively", "en_female_warm", "en_male", "en_female_british", "en_male_british"
    ]

    /// 画面比例：`auto` + `CanvasRatio` 里固定比例的那几个（按界面上的写法）。
    public static let canvasRatios = ["auto", "16:9", "9:16", "4:3", "3:4", "1:1"]

    /// = `ProjectFrameRate.allCases` 的帧数。
    public static let frameRates = [24, 30, 60]

    /// = `ResolutionLimit.allCases`，按短边写（1080p 的竖屏就是 1080×1920）。
    public static let resolutions = ["original", "2160p", "1440p", "1080p", "720p", "480p"]

    /// 文字的几个常用位置（画面高度的比例见 App 里的 `AITextPlacement`）。
    public static let textPositions = ["top", "upper_third", "center", "lower_third", "bottom"]

    /// 字幕放哪儿（= App 里 `AISubtitleStyleChange.positions` 的名字：九宫格里居中的那一列）。
    public static let subtitlePositions = ["bottom", "middle", "top"]

    /// = `ClipPresetKind.allCases` 的原始值（画面段的入场 / 出场）。
    public static let clipAnimations = ["none", "fade", "rise", "pop", "zoom", "wipe"]

    /// = `SoundSceneKind.allCases` 的原始值，前面加一个 "none"（去掉场景）。
    public static let soundScenes = ["none", "telephone", "megaphone", "radio", "room", "bathroom", "hall", "outdoor", "forest", "valley"]

    /// = `MarkerColor.allCases` 的原始值。
    public static let markerColors = ["red", "orange", "yellow", "green", "blue", "purple"]

    public static let textAlignments = ["left", "center", "right"]

    /// compress_videos / burn_subtitles 的画质三档（AIEncodeOptions 换成 CRF / 硬件质量）。
    public static let encodeQualities = ["small", "balanced", "high"]

    /// 压缩 / 烧录的帧率上限（只降不升，`FrameRateLimit`）。
    public static let frameRateLimits = ["original", "60", "30", "24"]

    /// convert_subtitles 能转成的格式（`SubtitleFormat` 的扩展名）。
    public static let subtitleFormats = ["srt", "vtt", "ass", "ssa", "txt"]

    public static var filterPresetIDs: [String] { filterPresets.map(\.id) }

    /// 滤镜说明里那一串「名字: 样子」。
    public static var filterPresetGuide: String {
        filterPresets.map { "\($0.id) (\($0.look))" }.joined(separator: ", ")
    }
}
