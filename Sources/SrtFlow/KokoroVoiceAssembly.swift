import Foundation
import SrtFlowKokoro

// MARK: - Kokoro 读出来的几段拼成一句旁白（纯值）
//
// 管什么：每一段按**第一个字开口、最后一个字说完**的时刻裁（模型给了每个 token 的时长，一格 600 个采样），头尾各留一点
// 余量再淡入淡出，段和段之间按标点停；同时算出每个字 / 词在整句声音里从第几个采样开始（`AIVoiceWords.Marker`），
// 字幕和 macOS 配音走同一条路（AIVoiceWords → SubtitleSegmenter）。
// 为什么按字的时刻裁、不按能量猜：Kokoro 读完之后常会冒一截杂音（2026-09-28 用户听出来「学完这门课」后面的卡顿声；
// speech-swift 按能量裁，这种够响的一截裁不掉）；时长是模型自己给的，最后一个字在哪结束是确定的。
// 不管什么：怎么切段（KokoroVoicePieces）、怎么读（KokoroVoiceSpeech）。

enum KokoroVoiceAssembly {
    /// 读好的一段。
    struct SpokenPiece {
        /// 在整句里的 UTF-16 位置。
        var range: Range<Int>
        var samples: [Float]
        /// 每个 token 的时长（格）。
        var frames: [Int]
        /// 单位的位置相对这一段。
        var units: [KokoroUnit]
        var pauseAfter: Double
    }

    /// 第一个字前面留多少（秒）：模型的声音和时长之间差一两格（2026-09-28 实测大多差一格，25 毫秒）。
    static let leadIn = 0.05
    /// 最后一个字说完之后，最多往后找多远的安静（秒）：声音可能比时长晚一两格；那截杂音在一段安静之后才冒出来
    /// （2026-09-28 那一截在安静 140 毫秒之后），在第一段安静处切就把它切掉了。
    static let tailSearch = 0.2
    /// 多安静算说完了：40 毫秒里的均方根低于它（Kokoro 说话时约 0.05–0.3）。
    static let quietRMS: Float = 0.006
    /// 头尾的淡入 / 淡出（秒），免得切口「咔」一声。
    static let fadeIn = 0.005
    static let fadeOut = 0.015

    static func assemble(_ pieces: [SpokenPiece], sampleRate: Int, samplesPerFrame: Int)
        -> (samples: [Float], markers: [AIVoiceWords.Marker]) {
        var output: [Float] = []
        var markers: [AIVoiceWords.Marker] = []
        let rate = Double(sampleRate)
        for piece in pieces {
            guard let first = piece.units.first, let last = piece.units.last, !piece.samples.isEmpty else { continue }
            var cumulative = [0]
            for frames in piece.frames { cumulative.append(cumulative[cumulative.count - 1] + frames) }
            func sample(atToken index: Int) -> Int { cumulative[min(index, cumulative.count - 1)] * samplesPerFrame }
            let from = max(0, sample(atToken: first.tokenRange.lowerBound) - Int(leadIn * rate))
            let to = speechEnd(piece.samples, nominal: sample(atToken: last.tokenRange.upperBound), rate: rate)
            guard to > from else { continue }
            var cut = Array(piece.samples[from..<to])
            fade(&cut, fadeIn: Int(fadeIn * rate), fadeOut: Int(fadeOut * rate))
            let base = output.count
            for unit in piece.units {
                // 词尾多给一格（声音比时长晚一两格），但不超过这一段切下来的长度。
                let end = sample(atToken: unit.tokenRange.upperBound) + samplesPerFrame
                markers.append(AIVoiceWords.Marker(
                    location: piece.range.lowerBound + unit.textRange.lowerBound, length: unit.textRange.count,
                    frame: base + max(0, sample(atToken: unit.tokenRange.lowerBound) - from),
                    endFrame: base + min(to, max(from, end)) - from
                ))
            }
            output += cut
            output += [Float](repeating: 0, count: Int(piece.pauseAfter * rate))
        }
        return (output, markers)
    }

    /// 最后一个字（按时长）结束前 40 毫秒起，往后找第一段 40 毫秒的安静，切在它里面 10 毫秒；找不到就切在 `tailSearch` 处。
    static func speechEnd(_ samples: [Float], nominal: Int, rate: Double) -> Int {
        let window = Int(0.04 * rate)
        let step = Int(0.01 * rate)
        let limit = min(samples.count, nominal + Int(tailSearch * rate))
        var position = max(0, nominal - window)
        while position + window <= limit {
            var sum: Float = 0
            for index in position..<(position + window) { sum += samples[index] * samples[index] }
            if (sum / Float(window)).squareRoot() < quietRMS { return min(limit, position + step) }
            position += step
        }
        return limit
    }

    private static func fade(_ samples: inout [Float], fadeIn: Int, fadeOut: Int) {
        let inCount = min(fadeIn, samples.count)
        for index in 0..<inCount { samples[index] *= Float(index) / Float(max(inCount, 1)) }
        let outCount = min(fadeOut, samples.count)
        for offset in 0..<outCount {
            samples[samples.count - 1 - offset] *= Float(offset) / Float(max(outCount, 1))
        }
    }
}
