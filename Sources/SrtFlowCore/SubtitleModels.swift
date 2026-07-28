import Foundation

public enum SubtitleFormat: String, CaseIterable, Codable, Sendable {
    case text = "txt"
    case srt
    case vtt
    case ass
    case ssa

    public var displayName: String {
        switch self {
        case .text: return "Text"
        case .srt: return "SRT"
        case .vtt: return "VTT"
        case .ass: return "ASS"
        case .ssa: return "SSA"
        }
    }

    public var fileExtension: String { rawValue }

    public var utTypeIdentifier: String {
        switch self {
        case .text: return "public.plain-text"
        case .srt: return "com.srtflow.srt"
        case .vtt: return "org.w3.webvtt"
        case .ass: return "com.srtflow.ass"
        case .ssa: return "com.srtflow.ssa"
        }
    }

    public static func detect(from filename: String) -> SubtitleFormat? {
        let ext = (filename as NSString).pathExtension.lowercased()
        return SubtitleFormat(rawValue: ext)
    }
}

public struct SubtitleStyle: Codable, Hashable, Sendable {
    public var name: String
    public var fontName: String
    public var fontSize: Double
    public var primaryColour: String
    public var secondaryColour: String
    public var outlineColour: String
    public var backColour: String
    public var bold: Bool
    public var italic: Bool
    public var underline: Bool
    public var strikeOut: Bool
    public var scaleX: Double
    public var scaleY: Double
    public var spacing: Double
    public var angle: Double
    public var borderStyle: Int
    public var outline: Double
    public var shadow: Double
    public var alignment: Int
    public var marginL: Int
    public var marginR: Int
    public var marginV: Int
    public var encoding: Int

    public init(
        name: String = "Default",
        fontName: String = "Arial",
        fontSize: Double = 48,
        primaryColour: String = "&H00FFFFFF",
        secondaryColour: String = "&H000000FF",
        outlineColour: String = "&H00000000",
        backColour: String = "&H00000000",
        bold: Bool = false,
        italic: Bool = false,
        underline: Bool = false,
        strikeOut: Bool = false,
        scaleX: Double = 100,
        scaleY: Double = 100,
        spacing: Double = 0,
        angle: Double = 0,
        borderStyle: Int = 1,
        outline: Double = 2,
        shadow: Double = 0,
        alignment: Int = 2,
        marginL: Int = 10,
        marginR: Int = 10,
        marginV: Int = 10,
        encoding: Int = 1
    ) {
        self.name = name
        self.fontName = fontName
        self.fontSize = fontSize
        self.primaryColour = primaryColour
        self.secondaryColour = secondaryColour
        self.outlineColour = outlineColour
        self.backColour = backColour
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.strikeOut = strikeOut
        self.scaleX = scaleX
        self.scaleY = scaleY
        self.spacing = spacing
        self.angle = angle
        self.borderStyle = borderStyle
        self.outline = outline
        self.shadow = shadow
        self.alignment = alignment
        self.marginL = marginL
        self.marginR = marginR
        self.marginV = marginV
        self.encoding = encoding
    }

    public static let `default` = SubtitleStyle()
}

public struct SubtitleCue: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var index: Int
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    public var styleName: String
    public var layer: Int
    public var name: String
    public var marginL: Int?
    public var marginR: Int?
    public var marginV: Int?
    public var effect: String
    public var rawOverride: String?

    public init(
        id: UUID = UUID(),
        index: Int = 0,
        start: TimeInterval = 0,
        end: TimeInterval = 0,
        text: String = "",
        styleName: String = "Default",
        layer: Int = 0,
        name: String = "",
        marginL: Int? = nil,
        marginR: Int? = nil,
        marginV: Int? = nil,
        effect: String = "",
        rawOverride: String? = nil
    ) {
        self.id = id
        self.index = index
        self.start = start
        self.end = end
        self.text = text
        self.styleName = styleName
        self.layer = layer
        self.name = name
        self.marginL = marginL
        self.marginR = marginR
        self.marginV = marginV
        self.effect = effect
        self.rawOverride = rawOverride
    }

    public var duration: TimeInterval { max(0, end - start) }
}

public struct SubtitleDocumentModel: Codable, Hashable, Sendable {
    public var cues: [SubtitleCue]
    public var styles: [SubtitleStyle]
    public var format: SubtitleFormat
    public var title: String
    public var scriptInfo: [String: String]
    public var eventsFormat: String
    public var stylesFormat: String
    public var associatedVideoPath: String?

    public init(
        cues: [SubtitleCue] = [],
        styles: [SubtitleStyle] = [.default],
        format: SubtitleFormat = .srt,
        title: String = "Untitled",
        scriptInfo: [String: String] = [:],
        eventsFormat: String = "Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text",
        stylesFormat: String = "Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding",
        associatedVideoPath: String? = nil
    ) {
        self.cues = cues
        self.styles = styles.isEmpty ? [.default] : styles
        self.format = format
        self.title = title
        self.scriptInfo = scriptInfo
        self.eventsFormat = eventsFormat
        self.stylesFormat = stylesFormat
        self.associatedVideoPath = associatedVideoPath
    }

    public mutating func reindex() {
        for i in cues.indices {
            cues[i].index = i + 1
        }
    }

    public mutating func addCue(after index: Int? = nil) {
        let insertAt: Int
        if let index, index >= 0, index < cues.count {
            insertAt = index + 1
        } else {
            insertAt = cues.count
        }
        let previousEnd = insertAt > 0 ? cues[insertAt - 1].end : 0
        let cue = SubtitleCue(
            start: previousEnd,
            end: previousEnd,
            text: ""
        )
        cues.insert(cue, at: insertAt)
        reindex()
    }

    public mutating func removeCues(ids: Set<UUID>) {
        cues.removeAll { ids.contains($0.id) }
        reindex()
    }

    public func cue(at time: TimeInterval) -> SubtitleCue? {
        cues.first { time >= $0.start && time < $0.end }
    }
}
