import Foundation
import SrtFlowMCPKit

// MARK: - 工具：find_audio（搜 SrtFlow 的音乐库和音效库），以及 add_clips 的 library_id
//
// 管什么：方案第 14 条「AI 能补哪些素材：音频库配乐」+ 2026-09-30 的音效库。搜清单（`AudioLibraryManifest.filter`，界面上的
// 搜索框同一个函数：标题、艺人、中英文标签都能搜，几个词是「与」；`kind` 定搜哪个库），把一条放上时间线（和从音频库拖进来
// 一样：下载到缓存、带上 `remoteKey`，换机器 / 清了缓存也能重新拉回来；音效段默认 −8 dB，同合成音效）。
// 不管什么：清单怎么读、等清单（AudioLibraryLookup）、缓存（AudioLibraryStore / AudioLibraryCache）、落点（add_clips 那一路，
// AITimelineEdits）、一条写成什么样和署名句（纯值的 AIMusicCredits，自检够得着）。
//
// 音乐只收 CC-BY / CC0（docs/plans/2026-09-22-audio-library.md）：CC-BY 要在成片的说明里署名，结果里带着署名句，说明要求
// AI 告诉用户；音效是用户自己的（`owned`），不署。AI 的顺序（用户定）：先搜库、没有合适的用 add_clips 的 sound_effect 合成、
// 真实声音都没有才 generate_media —— 工具说明里写着，并叫 AI 别去网上下载。

@MainActor
enum AIAudioLibraryTools {
    /// find_audio 的 kind → 读哪几个库。
    private static func stores(for kind: String) -> [AudioLibraryStore] {
        switch kind {
        case "music": return [AudioLibraryStore.music]
        case "sound_effect": return [AudioLibraryStore.soundEffects]
        default: return AudioLibraryStore.all
        }
    }

    static func findAudio(_ args: AIToolArguments) async throws -> AIToolResult {
        let query = try args.string("query") ?? ""
        let kind = try args.choice("kind", from: MCPVocabulary.audioKinds) ?? "any"
        let limit = min(max(try args.int("max_results") ?? 10, 1), 50)
        let loaded = await AudioLibraryLookup.load(stores(for: kind))
        if loaded.items.isEmpty, let failure = loaded.failures.first { throw AIToolError(failure) }
        let matched = AudioLibraryManifest.filter(loaded.items, query: query)
        let cached = AudioLibraryCache.shared.cachedIDs
        var result: [String: JSONValue] = [
            "matched": .number(Double(matched.count)),
            "tracks": .array(matched.prefix(limit).map { AIMusicCredits.describe($0, downloaded: cached.contains($0.id)) }),
            "note": .string(
                "Add one with add_clips {\"library_id\": id}; a sound effect also takes hit_at (its hit is the second its loudest "
                + "moment is at). CC-BY music must be credited: tell the user to put the credit line in the video's description."
            )
        ]
        if loaded.stale { result["offline"] = "SrtFlow is offline and showing the last known list." }
        if !loaded.failures.isEmpty { result["warning"] = .string(loaded.failures.joined(separator: " ")) }
        return .ok(.object(result))
    }

    /// get_timeline 用：工程里用到的音频库素材的署名句。清单还没读好就先不写（顺手让它开始读，下次就有）。
    static func projectCredits(_ state: TimelineState) -> [String] {
        let keys = Set(state.allClips.compactMap(\.remoteKey))
        guard !keys.isEmpty else { return [] }
        return AIMusicCredits.lines(AudioLibraryLookup.loadedItems.filter { keys.contains($0.id) })
    }

    /// add_clips 的 library_id：两个库里找，下载（缓存里有就直接用），做成和从音频库拖进来一样的片段（带 `remoteKey`，
    /// 时长按清单；音效段默认 −8 dB）。
    static func libraryClip(id: String) async throws -> (clip: EditClip, item: AudioLibraryItem) {
        let loaded = await AudioLibraryLookup.load(AudioLibraryStore.all)
        guard let item = loaded.items.first(where: { $0.id == id }) else {
            let why = loaded.failures.isEmpty ? "Use find_audio for ids." : loaded.failures.joined(separator: " ")
            throw AIToolError("There is no \(id) in SrtFlow's audio libraries. \(why)")
        }
        let url: URL
        do {
            url = try await AudioLibraryCache.shared.download(item)
        } catch {
            throw AIToolError("SrtFlow could not download \(item.title): \(error.localizedDescription)")
        }
        var clip = EditClip(
            sourceURL: url, isAudioOnly: true, sourceDuration: item.duration,
            audioAssetDuration: item.duration, remoteKey: item.id
        )
        clip.volume = AudioGain.linear(fromDecibels: item.defaultClipGainDB)
        return (clip, item)
    }
}
