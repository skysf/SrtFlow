import CoreGraphics
import Foundation
import SrtFlowMCPKit

// MARK: - 画面里一直在的字：烧进去的字幕带、固定的字（水印）、满屏的字（纯值）
//
// 管什么：look text_scan 隔一会儿认一帧字（AIVision，带框），这里把几十帧叠起来统计（方案第 55 条）：
// - **字幕带**：画面最下面、正中的一行字，很多帧都有、字一直在变 —— 烧进画面的字幕。报它占的那一条。只认下面：
//   2026-09-28 拿课程录屏实测，居中的幻灯片标题会被当成「顶上的字幕」，顶上的烧录字幕又少见。
// - **固定的字**：同样的字很多帧都有 —— 水印、台标、固定的标题、录屏里的界面文字。大多在同一个地方的报那个框；
//   在几个地方来回出现的（会跳角的水印，同一批素材里就有）报「会动」和它去过的几处。挨着的几个词（「Sky」「Studio」）并成一块。
//   OCR 认小字、淡字并不稳（同一个水印 24 帧里只认出 3–17 帧），所以门槛放在三成；不是字的台标认不出来。
// - **满屏的字**：除去上面两样，很多帧里字多（幻灯片、录屏：和 AISubjectFocus 按字对准同一个「字多」）。报它们通常
//   占的那一块 —— 竖屏取景用 edit_clip focus=text。
// 坐标都是源画面上的归一化值、左上原点。纯值，自检够得着（scripts/check-mcp.sh）。
// 不管什么：怎么抽帧、怎么认（AILookText、AIVision）。

enum AITextRegions {
    struct Frame {
        var time: Double
        var texts: [AIVision.Text]
    }

    struct Band: Equatable {
        var box: CGRect
        /// 多少比例的帧有它。
        var coverage: Double
        var from: Double
        var to: Double
    }

    struct Fixed: Equatable {
        var text: String
        /// 最常出现的那一处。
        var box: CGRect
        var coverage: Double
        /// 在几个地方来回出现（会跳角的水印）：它去过的几处；只在一处就是空的。
        var places: [CGRect] = []
    }

    struct Heavy: Equatable {
        var coverage: Double
        var box: CGRect
    }

    struct Report: Equatable {
        var band: Band?
        var fixed: [Fixed] = []
        var heavy: Heavy?
    }

    /// 字幕带至少这么多帧有字、字换过这么多次（不同的字 / 有字的帧）；固定的字至少三成的帧有；满屏的字至少四成的帧。
    static let bandCoverage = 0.25
    static let bandChanges = 0.4
    static let fixedCoverage = 0.3
    static let heavyCoverage = 0.4
    /// 两块字的中心相差不到它就算同一个地方。
    static let samePlace = 0.05
    /// 两行字的底边相差不到它（画面高的比例）就算字幕的同一个位置。
    static let sameBaseline = 0.02
    /// 字幕上面那一行（折行的第二行）至少有这么多句不同的话才认；只有一帧、或者一页停几帧都是同一句的，是幻灯片自己的字。
    static let minWrappedTexts = 2
    /// 同一个字大多（八成）出现在同一处才算「固定在那儿」，不然算会动。
    static let settled = 0.8
    /// 框的底边到了这儿（画面高的比例）就是贴着画面底边；一行字幕至少这么高（1080 高的画面上约 43 像素）。
    static let bottomEdge = 0.99
    static let shortestLine = 0.04
    /// 字幕那一堆至少有这么多句不同的话，也至少是最多那一堆的 1/rowShare。
    static let minSubtitleTexts = 3
    static let rowShare = 3

    static func report(_ frames: [Frame]) -> Report {
        guard !frames.isEmpty else { return Report() }
        // 先认出固定的字、拿掉它们再找字幕带和满屏的字：底部正中一行不变的标题会把字幕带撑大、把没有字幕的帧也算进去。
        let groups = fixedGroups(frames)
        let fixedKeys = Set(groups.map(\.key))
        let moving = frames.map { frame in
            Frame(time: frame.time, texts: frame.texts.filter { !fixedKeys.contains(normalized($0.string)) })
        }
        let band = band(moving)
        return Report(band: band, fixed: merged(groups.map(\.fixed)), heavy: heavy(moving, band: band))
    }

    // MARK: 字幕带

    /// 像一行字幕：正中（中心离正中不超过画面宽的 12%）、够宽、不太高，在画面最下面那一截（中心在 78% 以下），
    /// 而且不是贴着画面底边被切掉的字。「不太高」这一条是有意的：一行字幕的框被花背景量大（L27 的 0.860–1.001，字形只在 0.90–0.965）
    /// 时不算字幕行，算进去会多裁 0.04；六节课 292 帧有字幕的画面里没有一处真的两行合并成一个框。
    static func captionLike(_ box: CGRect) -> Bool {
        box.width >= 0.06 && box.height <= 0.12 && abs(box.midX - 0.5) <= 0.12 && box.midY >= 0.78 && !cutOffAtBottom(box)
    }

    /// 贴着画面底边、只露出上面一道的字：幻灯片 / 网页 / PDF 往下滚出画面的那一行（录屏里到处都是）。框的底边就是画面边缘
    /// （实测 0.997）、高度只有一行的一小半（0.011–0.028）；烧进去的字幕离底边总留着空（六节课底边 0.95–0.98），一行至少 0.04 高。
    /// 让它们进字幕那一堆，每帧滚到不同的一行、字一直在变，「不同的字最多」就偏袒它们，把框的底边抬到 0.997，字幕离得远时干脆一个人赢。
    static func cutOffAtBottom(_ box: CGRect) -> Bool {
        box.maxY >= bottomEdge && box.height < shortestLine
    }

    private static func band(_ frames: [Frame]) -> Band? {
        let lit = frames.compactMap { frame -> (time: Double, texts: [AIVision.Text])? in
            let texts = frame.texts.filter { captionLike($0.box) }
            return texts.isEmpty ? nil : (frame.time, texts)
        }
        guard lit.count >= 3, let first = lit.first, let last = lit.last else { return nil }
        let coverage = Double(lit.count) / Double(frames.count)
        // 字一直在变才是字幕；总是同一行字的是固定的标题（归到固定的字）。
        let lines = Set(lit.map { normalized($0.texts.map(\.string).joined(separator: " ")) })
        guard coverage >= bandCoverage, Double(lines.count) / Double(lit.count) >= bandChanges else { return nil }
        let boxes = subtitleLines(lit.map(\.texts))
        guard !boxes.isEmpty else { return nil }
        let top = percentile(boxes.map(\.minY), 0.1)
        let bottom = percentile(boxes.map(\.maxY), 0.9)
        let left = percentile(boxes.map(\.minX), 0.1)
        let right = percentile(boxes.map(\.maxX), 0.9)
        return Band(box: CGRect(x: left, y: top, width: right - left, height: bottom - top),
                    coverage: coverage, from: first.time, to: last.time)
    }

    /// 字幕带的框只量字幕那几行（2026-09-29 验收实剪：课程录屏里居中的幻灯片字把框从 0.90 撑到 0.77，照「裁 0.24」
    /// 会切掉幻灯片自己的标签，docs/bugfixes/2026-09-29-text-scan-band-swallows-slide-labels.md）。烧进去的字幕底边在同一条线上、
    /// 字一直在换；幻灯片自己的字随页换位置、一页停几帧就是同一句。所以按底边分堆，**字幕是够多的那几堆里最下面的一堆**：
    /// 「够多」= 至少 3 句不同的话、也至少是最多那一堆的三分之一。不是「不同的字最多」—— 字幕稀疏、幻灯片的字多时（L27 的生产抽样，
    /// 24 帧里 4 帧有字幕、幻灯片 0.80–0.84 一段里有 7 句不同的字）最多的是幻灯片，框从 0.76 起、叫人裁 0.25；字幕总排在画面最下面，
    /// 它下面再有的东西不是被切掉的字（`cutOffAtBottom` 先滤掉）就是台标、页脚，撑不起三句。选定后按这一堆底边的中位数重新收一遍。
    /// 再带上同一帧里紧贴在字幕上面、一样大的字（两行的字幕）—— 这一行也要像字幕一样每句都换（至少两帧、两句不同）才认：幻灯片自己的
    /// 标题恰好贴在字幕上面的一帧不是第二行（2026-09-29 复查，docs/bugfixes/2026-09-29-text-scan-crop-hint-stretched-by-slide-title.md）。
    /// 没有一堆够格就是没有字幕（空）。
    static func subtitleLines(_ frames: [[AIVision.Text]]) -> [CGRect] {
        let lines = frames.enumerated().flatMap { index, texts in texts.map { (frame: index, text: $0) } }
        let piles = lines.map { candidate -> (bottom: Double, distinct: Int) in
            let same = lines.filter { abs($0.text.box.maxY - candidate.text.box.maxY) <= sameBaseline }
            return (Double(candidate.text.box.maxY), Set(same.map { normalized($0.text.string) }).count)
        }
        let most = piles.map(\.distinct).max() ?? 0
        let needed = max(minSubtitleTexts, (most + rowShare - 1) / rowShare)
        guard let lowest = piles.filter({ $0.distinct >= needed }).max(by: { ($0.bottom, $0.distinct) < ($1.bottom, $1.distinct) }) else { return [] }
        // 最下面那个候选只看得到它上面 0.02 以内的字，等于收了半堆：以这一堆底边的中位数为中心再收一遍。
        let center = median(lines.map { Double($0.text.box.maxY) }.filter { abs($0 - lowest.bottom) <= sameBaseline })
        let row = lines.filter { abs(Double($0.text.box.maxY) - center) <= sameBaseline }
        var boxes = row.map(\.text.box)
        var uppers: [Int: [AIVision.Text]] = [:]
        for line in row {
            let box = line.text.box
            // 紧贴在上面：空隙不到行高的四分之一（也不深压进来）、字高差两成以内、左右有重叠。
            uppers[line.frame, default: []] += frames[line.frame].filter { above in
                let gap = box.minY - above.box.maxY
                return above.box.maxY < box.maxY - sameBaseline && abs(gap) <= box.height * 0.25
                    && above.box.height >= box.height * 0.8 && above.box.height <= box.height * 1.25
                    && above.box.maxX > box.minX && above.box.minX < box.maxX
            }
        }
        let changing = Set(uppers.values.map { texts in texts.map { normalized($0.string) }.joined(separator: " ") }.filter { !$0.isEmpty })
        if changing.count >= minWrappedTexts { boxes += uppers.values.flatMap { $0.map(\.box) } }
        return boxes
    }

    // MARK: 固定的字

    /// 同一个字（只看字母数字、至少 3 个）三成以上的帧都有：按出现的地方分堆，最大的一堆占八成以上就是固定在那儿，
    /// 不然报它去过的几处（每处至少出现两次）。
    private static func fixedGroups(_ frames: [Frame]) -> [(key: String, fixed: Fixed)] {
        var sightings: [String: [(frame: Int, text: AIVision.Text)]] = [:]
        for (index, frame) in frames.enumerated() {
            for text in frame.texts {
                let key = normalized(text.string)
                if key.count >= 3 { sightings[key, default: []].append((index, text)) }
            }
        }
        var result: [(key: String, fixed: Fixed)] = []
        for (key, seen) in sightings {
            let coverage = Double(Set(seen.map(\.frame)).count) / Double(frames.count)
            guard Set(seen.map(\.frame)).count >= 3, coverage >= fixedCoverage else { continue }
            var places: [[AIVision.Text]] = []
            for sighting in seen {
                if let index = places.firstIndex(where: { near($0[0].box, sighting.text.box, within: samePlace * 1.6) }) {
                    places[index].append(sighting.text)
                } else {
                    places.append([sighting.text])
                }
            }
            places.sort { $0.count > $1.count }
            let main = places[0]
            let settledThere = Double(main.count) / Double(seen.count) >= settled
            let boxes = main.map(\.box)
            let box = CGRect(x: median(boxes.map { Double($0.minX) }), y: median(boxes.map { Double($0.minY) }),
                             width: median(boxes.map { Double($0.width) }), height: median(boxes.map { Double($0.height) }))
            let others = settledThere ? [] : places.filter { $0.count >= 2 }.map { $0[0].box }
            result.append((key, Fixed(text: mostCommon(seen.map(\.text.string)), box: box, coverage: coverage, places: others)))
        }
        return result.sorted { $0.fixed.coverage == $1.fixed.coverage ? $0.key < $1.key : $0.fixed.coverage > $1.fixed.coverage }
    }

    /// 固定在同一处、挨着的几个词（左右挨着，或者上下叠着的两行）并成一块（「Sky」「Studio」→「Sky Studio」）；最多报 4 块。
    private static func merged(_ fixed: [Fixed]) -> [Fixed] {
        var result: [Fixed] = []
        for mark in fixed.sorted(by: { $0.box.minX < $1.box.minX }) {
            if mark.places.isEmpty, let index = result.lastIndex(where: { other in
                other.places.isEmpty && abs(other.box.midY - mark.box.midY) <= 1.5 * max(mark.box.height, other.box.height)
                    && mark.box.minX - other.box.maxX <= 0.03 && mark.box.minX >= other.box.minX
            }) {
                // 按读的顺序拼：在上面一行的放前面（台标常是「Sky」叠在「Studio」上面）。
                let above = mark.box.maxY <= result[index].box.minY + 0.005
                result[index].text = above ? mark.text + " " + result[index].text : result[index].text + " " + mark.text
                result[index].box = result[index].box.union(mark.box)
                result[index].coverage = max(result[index].coverage, mark.coverage)
            } else {
                result.append(mark)
            }
        }
        return Array(result.sorted { $0.coverage == $1.coverage ? $0.text < $1.text : $0.coverage > $1.coverage }.prefix(4))
    }

    private static func near(_ a: CGRect, _ b: CGRect, within distance: Double) -> Bool {
        abs(a.midX - b.midX) <= distance && abs(a.midY - b.midY) <= distance
    }

    // MARK: 满屏的字

    /// `frames` 里已经拿掉了固定的字（同样的字出现在哪儿都算）。
    private static func heavy(_ frames: [Frame], band: Band?) -> Heavy? {
        var unions: [CGRect] = []
        for frame in frames {
            let rest = frame.texts.filter { text in
                guard let band else { return true }
                return !band.box.insetBy(dx: -0.02, dy: -0.02).contains(CGPoint(x: text.box.midX, y: text.box.midY))
            }
            guard let first = rest.first, AISubjectFocus.isTextHeavy(rest.map(\.box)) else { continue }
            unions.append(rest.dropFirst().reduce(first.box) { $0.union($1.box) })
        }
        let coverage = Double(unions.count) / Double(frames.count)
        guard coverage >= heavyCoverage else { return nil }
        let left = median(unions.map { Double($0.minX) })
        let right = median(unions.map { Double($0.maxX) })
        let top = median(unions.map { Double($0.minY) })
        let bottom = median(unions.map { Double($0.maxY) })
        return Heavy(coverage: coverage, box: CGRect(x: left, y: top, width: right - left, height: bottom - top))
    }

    // MARK: 写给 AI

    /// `timeline`：看的是时间线上的一段时，源秒换成时间线秒。
    static func json(_ report: Report, timeline: (Double) -> Double = { $0 }) -> [String: JSONValue] {
        var object: [String: JSONValue] = [:]
        if let band = report.band {
            let cut = 1 - band.box.minY + 0.01
            object["subtitle_band"] = [
                "where": "bottom",
                "box": AIFrameDescription.box(band.box),
                "in_frames": fraction(band.coverage),
                "from": AIFormat.seconds(timeline(band.from)),
                "to": AIFormat.seconds(timeline(band.to)),
                "hint": .string("Subtitles burned into the picture. Put new subtitles elsewhere (edit_subtitles style), or cut "
                    + "them off with edit_clip crop bottom \(String(format: "%.2f", cut)). The crop takes off everything in that "
                    + "strip, also a slide's own text near the bottom edge: look at a few frames after cropping.")
            ]
        }
        if !report.fixed.isEmpty {
            object["fixed_text"] = .array(report.fixed.map { mark in
                var entry: [String: JSONValue] = [
                    "text": .string(mark.text), "box": AIFrameDescription.box(mark.box), "in_frames": fraction(mark.coverage)
                ]
                if !mark.places.isEmpty {
                    entry["moves"] = true
                    entry["places"] = .array(mark.places.map(AIFrameDescription.box))
                }
                return .object(entry)
            })
            object["fixed_text_hint"] = "Text that keeps coming back: a watermark, a logo, a fixed title or an app's own labels (moves=true: it jumps between places). Small or faint marks and logos without text can be missed; look at a few frames to be sure."
        }
        if let heavy = report.heavy {
            object["text_heavy"] = [
                "box": AIFrameDescription.box(heavy.box),
                "in_frames": fraction(heavy.coverage),
                "hint": "Slides or a screen full of text. To reframe for 9:16 use edit_clip fit=fill focus=text (it says how much text falls outside); fit=fit keeps all of it."
            ]
        }
        if object.isEmpty { object["found"] = "No text stays on screen." }
        return object
    }

    // MARK: 小件

    /// 比字用：只留字母和数字，小写。
    static func normalized(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    private static func mostCommon(_ texts: [String]) -> String {
        var counts: [String: Int] = [:]
        for text in texts { counts[text, default: 0] += 1 }
        return counts.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key ?? ""
    }

    private static func median(_ values: [Double]) -> Double {
        percentile(values, 0.5)
    }

    private static func percentile(_ values: [CGFloat], _ p: Double) -> Double {
        percentile(values.map { Double($0) }, p)
    }

    private static func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let position = p * Double(sorted.count - 1)
        let low = Int(position.rounded(.down))
        let high = min(sorted.count - 1, low + 1)
        return sorted[low] + (sorted[high] - sorted[low]) * (position - Double(low))
    }

    private static func fraction(_ value: Double) -> JSONValue {
        .number((value * 100).rounded() / 100)
    }
}
