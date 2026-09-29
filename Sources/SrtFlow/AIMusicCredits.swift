import Foundation
import SrtFlowMCPKit

// MARK: - 音乐库写给 AI 看（纯值）：一首的样子、署名句
//
// 管什么：find_audio 结果里每一首写什么（时长、英文标签、激烈程度、人声、响度、授权、署名句），以及
// 「这些素材要署哪几句名」（add_clips 的结果、get_timeline 的 music_credits 都用它）。
// 不管什么：读清单、下载（AIAudioLibraryTools，要网络和缓存，自检够不着）。
//
// 署名口径和署名页（AudioLibraryCredits）同一个：句子原样用清单给的 `license.text`，自己拼会在换音源时悄悄写错；
// CC0 不用署名，其余（CC-BY）都要。

enum AIMusicCredits {
    /// 要署的名：CC0 以外的每一首，按艺人、标题排，同一句只出现一次。
    static func lines(_ items: [AudioLibraryItem]) -> [String] {
        let needed = items.filter { !$0.license.code.uppercased().hasPrefix("CC0") }
        var seen = Set<String>()
        return needed.sorted { ($0.artist, $0.title) < ($1.artist, $1.title) }
            .map(\.license.text)
            .filter { seen.insert($0).inserted }
    }

    /// 一首的样子（给 AI 挑）。标签写英文（模型读英文最准；中文照样能搜，搜的是清单里的两种写法）。
    static func describe(_ item: AudioLibraryItem, downloaded: Bool) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(item.id),
            "title": .string(item.title),
            "artist": .string(item.artist),
            "duration": AIFormat.seconds(item.duration),
            "tags": .array(item.tags.map { .string($0.en) }),
            "intensity": .number(Double(item.intensity)),
            "license": .string(item.license.code),
            "credit": .string(item.license.text)
        ]
        if item.hasVocals { object["vocals"] = true }
        if let loudness = item.loudness { object["loudness_lufs"] = .number((loudness * 10).rounded() / 10) }
        if downloaded { object["downloaded"] = true }
        return .object(object)
    }
}
