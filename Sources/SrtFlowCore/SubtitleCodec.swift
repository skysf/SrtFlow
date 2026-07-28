import Foundation

/// Parses subtitle file contents into a `SubtitleDocumentModel`.
public enum SubtitleParser {

    public static func parse(_ content: String, format: SubtitleFormat, filename: String = "") -> SubtitleDocumentModel {
        var doc: SubtitleDocumentModel
        switch format {
        case .srt: doc = parseSRT(content)
        case .vtt: doc = parseVTT(content)
        case .ass: doc = parseASS(content, ssa: false)
        case .ssa: doc = parseASS(content, ssa: true)
        case .text: doc = parseText(content)
        }
        doc.format = format
        if !filename.isEmpty {
            doc.title = (filename as NSString).deletingPathExtension
        }
        doc.reindex()
        return doc
    }

    // MARK: - SRT

    static func parseSRT(_ content: String) -> SubtitleDocumentModel {
        var cues: [SubtitleCue] = []
        for block in blocks(in: content) {
            guard let timeLineIndex = block.firstIndex(where: { $0.contains("-->") }),
                  let range = parseTimeRange(block[timeLineIndex]) else { continue }
            let text = block[(timeLineIndex + 1)...].joined(separator: "\n")
            cues.append(SubtitleCue(start: range.start, end: range.end, text: text))
        }
        return SubtitleDocumentModel(cues: cues, styles: [.default])
    }

    // MARK: - VTT

    static func parseVTT(_ content: String) -> SubtitleDocumentModel {
        var cues: [SubtitleCue] = []
        for block in blocks(in: content) {
            // A cue block has "-->" in its first line, or in the second line after an identifier.
            guard let timeLineIndex = block.firstIndex(where: { $0.contains("-->") }),
                  timeLineIndex <= 1,
                  let range = parseTimeRange(block[timeLineIndex]) else { continue }
            let text = block[(timeLineIndex + 1)...].joined(separator: "\n")
            cues.append(SubtitleCue(start: range.start, end: range.end, text: text))
        }
        return SubtitleDocumentModel(cues: cues, styles: [.default])
    }

    // MARK: - ASS / SSA

    static func parseASS(_ content: String, ssa: Bool) -> SubtitleDocumentModel {
        var doc = SubtitleDocumentModel(cues: [], styles: [])
        if ssa {
            doc.stylesFormat = "Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, TertiaryColour, BackColour, Bold, Italic, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, AlphaLevel, Encoding"
            doc.eventsFormat = "Marked, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text"
        }

        enum Section { case none, scriptInfo, styles, events }
        var section: Section = .none
        var styleFields: [String] = []
        var eventFields: [String] = []
        var parsedStyles: [SubtitleStyle] = []

        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .init(charactersIn: " \t\r"))
            if line.isEmpty { continue }

            if line.hasPrefix("[") {
                let lower = line.lowercased()
                if lower.contains("script info") { section = .scriptInfo }
                else if lower.hasPrefix("[v4") { section = .styles }
                else if lower.contains("events") { section = .events }
                else { section = .none }
                continue
            }

            switch section {
            case .scriptInfo:
                if line.hasPrefix(";") { continue }
                if let colon = line.firstIndex(of: ":") {
                    let key = line[..<colon].trimmingCharacters(in: .whitespaces)
                    let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    doc.scriptInfo[key] = value
                }
            case .styles:
                if let rest = stripPrefix(line, prefix: "Format:") {
                    doc.stylesFormat = rest
                    styleFields = rest.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                } else if let rest = stripPrefix(line, prefix: "Style:") {
                    let values = rest.split(separator: ",", maxSplits: styleFields.count - 1, omittingEmptySubsequences: false)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                    parsedStyles.append(parseStyle(values: values, fields: styleFields, ssa: ssa))
                }
            case .events:
                if let rest = stripPrefix(line, prefix: "Format:") {
                    doc.eventsFormat = rest
                    eventFields = rest.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                } else if let rest = stripPrefix(line, prefix: "Dialogue:") {
                    let values = rest.split(separator: ",", maxSplits: eventFields.count - 1, omittingEmptySubsequences: false)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                    if let cue = parseEvent(values: values, fields: eventFields) {
                        doc.cues.append(cue)
                    }
                }
            case .none:
                continue
            }
        }

        doc.styles = parsedStyles.isEmpty ? [.default] : parsedStyles
        return doc
    }

    static func parseStyle(values: [String], fields: [String], ssa: Bool) -> SubtitleStyle {
        var style = SubtitleStyle()
        for (index, field) in fields.enumerated() where index < values.count {
            let value = values[index]
            switch field {
            case "name": style.name = value
            case "fontname": style.fontName = value
            case "fontsize": style.fontSize = Double(value) ?? style.fontSize
            case "primarycolour": style.primaryColour = value
            case "secondarycolour": style.secondaryColour = value
            case "outlinecolour": style.outlineColour = value
            case "tertiarycolour": if ssa { style.outlineColour = value }
            case "backcolour": style.backColour = value
            case "bold": style.bold = (Int(value) ?? 0) != 0
            case "italic": style.italic = (Int(value) ?? 0) != 0
            case "underline": style.underline = (Int(value) ?? 0) != 0
            case "strikeout": style.strikeOut = (Int(value) ?? 0) != 0
            case "scalex": style.scaleX = Double(value) ?? style.scaleX
            case "scaley": style.scaleY = Double(value) ?? style.scaleY
            case "spacing": style.spacing = Double(value) ?? style.spacing
            case "angle": style.angle = Double(value) ?? style.angle
            case "borderstyle": style.borderStyle = Int(value) ?? style.borderStyle
            case "outline": style.outline = Double(value) ?? style.outline
            case "shadow": style.shadow = Double(value) ?? style.shadow
            case "alignment": style.alignment = Int(value) ?? style.alignment
            case "marginl": style.marginL = Int(value) ?? style.marginL
            case "marginr": style.marginR = Int(value) ?? style.marginR
            case "marginv": style.marginV = Int(value) ?? style.marginV
            case "encoding": style.encoding = Int(value) ?? style.encoding
            default: break
            }
        }
        return style
    }

    static func parseEvent(values: [String], fields: [String]) -> SubtitleCue? {
        var cue = SubtitleCue()
        var sawTime = false
        for (index, field) in fields.enumerated() where index < values.count {
            let value = values[index]
            switch field {
            case "layer": cue.layer = Int(value) ?? 0
            case "marked": cue.layer = Int(value.replacingOccurrences(of: "Marked=", with: "")) ?? 0
            case "start":
                guard let t = Timecode.parse(value) else { return nil }
                cue.start = t; sawTime = true
            case "end":
                guard let t = Timecode.parse(value) else { return nil }
                cue.end = t
            case "style": cue.styleName = value
            case "name", "actor": cue.name = value
            case "marginl": cue.marginL = Int(value)
            case "marginr": cue.marginR = Int(value)
            case "marginv": cue.marginV = Int(value)
            case "effect": cue.effect = value
            case "text": cue.text = value
            default: break
            }
        }
        return sawTime ? cue : nil
    }

    // MARK: - Plain text

    /// Supports SRT-style time lines (`00:00:01,000 --> 00:00:03,500` + text lines),
    /// bracket timestamps (`[00:00:01.000] text`) and lines without any time (0/0).
    static func parseText(_ content: String) -> SubtitleDocumentModel {
        var cues: [SubtitleCue] = []
        let lines = content.components(separatedBy: .newlines)
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { index += 1; continue }

            if let range = parseTimeRange(trimmed) {
                // Style A: time line followed by text lines until a blank line.
                var textLines: [String] = []
                var next = index + 1
                while next < lines.count, !lines[next].trimmingCharacters(in: .whitespaces).isEmpty {
                    textLines.append(lines[next])
                    next += 1
                }
                cues.append(SubtitleCue(start: range.start, end: range.end, text: textLines.joined(separator: "\n")))
                index = next
            } else if let bracket = parseBracketLine(trimmed) {
                cues.append(SubtitleCue(start: bracket.time, end: bracket.time, text: bracket.text))
                index += 1
            } else {
                cues.append(SubtitleCue(start: 0, end: 0, text: line))
                index += 1
            }
        }
        return SubtitleDocumentModel(cues: cues, styles: [.default])
    }

    // MARK: - Helpers

    /// Splits content into non-empty blocks separated by blank lines (CRLF-safe).
    static func blocks(in content: String) -> [[String]] {
        var result: [[String]] = []
        var current: [String] = []
        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.replacingOccurrences(of: "\r", with: "")
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty { result.append(current); current = [] }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Parses `start --> end`, ignoring anything after the end time (e.g. VTT cue settings).
    static func parseTimeRange(_ line: String) -> (start: TimeInterval, end: TimeInterval)? {
        guard let arrowRange = line.range(of: "-->") else { return nil }
        let startString = line[..<arrowRange.lowerBound].trimmingCharacters(in: .whitespaces)
        let afterArrow = line[arrowRange.upperBound...].trimmingCharacters(in: .whitespaces)
        let endString = afterArrow.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
        guard let start = Timecode.parse(startString), let end = Timecode.parse(endString) else { return nil }
        return (start, end)
    }

    /// Parses `[00:00:01.000] text`.
    static func parseBracketLine(_ line: String) -> (time: TimeInterval, text: String)? {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
        let timeString = line[line.index(after: line.startIndex)..<close]
        guard let time = Timecode.parse(String(timeString)) else { return nil }
        let text = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
        return (time, text)
    }

    static func stripPrefix(_ line: String, prefix: String) -> String? {
        guard line.count > prefix.count,
              line.prefix(prefix.count).caseInsensitiveCompare(prefix) == .orderedSame else { return nil }
        return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }
}

/// Serializes a `SubtitleDocumentModel` into subtitle file contents.
public enum SubtitleSerializer {

    public static func serialize(_ doc: SubtitleDocumentModel, format: SubtitleFormat) -> String {
        switch format {
        case .srt: return serializeSRT(doc)
        case .vtt: return serializeVTT(doc)
        case .text: return serializeText(doc)
        case .ass: return serializeASS(doc, ssa: false)
        case .ssa: return serializeASS(doc, ssa: true)
        }
    }

    // MARK: - SRT / VTT / Text

    static func serializeSRT(_ doc: SubtitleDocumentModel) -> String {
        var out = ""
        for (index, cue) in doc.cues.enumerated() {
            out += "\(index + 1)\n"
            out += "\(Timecode.formatMillis(cue.start, separator: ",")) --> \(Timecode.formatMillis(cue.end, separator: ","))\n"
            out += plainText(cue.text) + "\n\n"
        }
        return out
    }

    static func serializeVTT(_ doc: SubtitleDocumentModel) -> String {
        var out = "WEBVTT\n\n"
        for cue in doc.cues {
            out += "\(Timecode.formatMillis(cue.start, separator: ".")) --> \(Timecode.formatMillis(cue.end, separator: "."))\n"
            out += plainText(cue.text) + "\n\n"
        }
        return out
    }

    static func serializeText(_ doc: SubtitleDocumentModel) -> String {
        // No timing information anywhere → emit plain lines, matching the no-timestamp import rule.
        if doc.cues.allSatisfy({ $0.start == 0 && $0.end == 0 }) {
            return doc.cues.map { plainText($0.text) }.joined(separator: "\n") + (doc.cues.isEmpty ? "" : "\n")
        }
        var out = ""
        for cue in doc.cues {
            out += "\(Timecode.formatMillis(cue.start, separator: ",")) --> \(Timecode.formatMillis(cue.end, separator: ","))\n"
            out += plainText(cue.text) + "\n\n"
        }
        return out
    }

    // MARK: - ASS / SSA

    static func serializeASS(_ doc: SubtitleDocumentModel, ssa: Bool) -> String {
        var out = "[Script Info]\n"
        var info = doc.scriptInfo
        info["ScriptType"] = ssa ? "v4.00" : "v4.00+"
        if info["Title"] == nil { info["Title"] = doc.title }
        let preferredOrder = ["Title", "ScriptType", "WrapStyle", "ScaledBorderAndShadow", "PlayResX", "PlayResY"]
        for key in preferredOrder where info[key] != nil {
            out += "\(key): \(info[key]!)\n"
            info[key] = nil
        }
        for key in info.keys.sorted() {
            out += "\(key): \(info[key]!)\n"
        }

        out += "\n[\(ssa ? "V4 Styles" : "V4+ Styles")]\n"
        let stylesFormat = ssa
            ? "Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, TertiaryColour, BackColour, Bold, Italic, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, AlphaLevel, Encoding"
            : doc.stylesFormat
        out += "Format: \(stylesFormat)\n"
        for style in doc.styles {
            out += "Style: \(styleLine(style, ssa: ssa))\n"
        }

        out += "\n[Events]\n"
        let eventsFormat = ssa
            ? "Marked, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text"
            : doc.eventsFormat
        out += "Format: \(eventsFormat)\n"
        for cue in doc.cues {
            out += "Dialogue: \(eventLine(cue, ssa: ssa))\n"
        }
        return out
    }

    static func styleLine(_ style: SubtitleStyle, ssa: Bool) -> String {
        func boolField(_ value: Bool) -> String { value ? "-1" : "0" }
        if ssa {
            return [
                style.name, style.fontName, trim(style.fontSize),
                style.primaryColour, style.secondaryColour, style.outlineColour, style.backColour,
                boolField(style.bold), boolField(style.italic),
                String(style.borderStyle), trim(style.outline), trim(style.shadow),
                String(style.alignment),
                margin(style.marginL), margin(style.marginR), margin(style.marginV),
                "0", String(style.encoding)
            ].joined(separator: ",")
        }
        return [
            style.name, style.fontName, trim(style.fontSize),
            style.primaryColour, style.secondaryColour, style.outlineColour, style.backColour,
            boolField(style.bold), boolField(style.italic), boolField(style.underline), boolField(style.strikeOut),
            trim(style.scaleX), trim(style.scaleY), trim(style.spacing), trim(style.angle),
            String(style.borderStyle), trim(style.outline), trim(style.shadow),
            String(style.alignment),
            margin(style.marginL), margin(style.marginR), margin(style.marginV),
            String(style.encoding)
        ].joined(separator: ",")
    }

    static func eventLine(_ cue: SubtitleCue, ssa: Bool) -> String {
        let text = assText(cue.text)
        if ssa {
            return [
                "0",
                Timecode.formatASS(cue.start), Timecode.formatASS(cue.end),
                cue.styleName, cue.name,
                margin(cue.marginL ?? 0), margin(cue.marginR ?? 0), margin(cue.marginV ?? 0),
                cue.effect, text
            ].joined(separator: ",")
        }
        return [
            String(cue.layer),
            Timecode.formatASS(cue.start), Timecode.formatASS(cue.end),
            cue.styleName, cue.name,
            margin(cue.marginL ?? 0), margin(cue.marginR ?? 0), margin(cue.marginV ?? 0),
            cue.effect, text
        ].joined(separator: ",")
    }

    // MARK: - Text conversion helpers

    /// Strips ASS override tags (`{\...}`) and converts `\N` / `\h` for plain-text targets.
    public static func plainText(_ text: String) -> String {
        var result = text
        while let range = result.range(of: "\\{[^}]*\\}", options: .regularExpression) {
            result.removeSubrange(range)
        }
        return result
            .replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\h", with: " ")
    }

    /// Converts newlines to ASS hard line breaks for ASS/SSA targets.
    public static func assText(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: "\\N")
    }

    static func margin(_ value: Int) -> String {
        String(format: "%04d", value)
    }

    /// `48.0` → `"48"`, keeps non-integral values as-is.
    static func trim(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(value)) : String(value)
    }
}
