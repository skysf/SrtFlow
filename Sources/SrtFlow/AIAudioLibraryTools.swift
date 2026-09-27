import Foundation
import SrtFlowMCPKit

// MARK: - 工具：find_audio（搜 SrtFlow 的音乐库），以及 add_clips 的 library_id
//
// 管什么：方案第 14 条「AI 能补哪些素材：音频库配乐」。搜音乐库的清单（`AudioLibraryManifest.filter`，界面上的搜索框
// 同一个函数：标题、艺人、中英文标签都能搜，几个词是「与」），把一首放上时间线（和从音频库拖进来一样：下载到缓存、
// 带上 `remoteKey`，换机器 / 清了缓存也能重新拉回来）。
// 不管什么：清单怎么读、怎么缓存（AudioLibraryStore / AudioLibraryCache）、落点（add_clips 那一路，AITimelineEdits）、
// 一首写成什么样和署名句（纯值的 AIMusicCredits，自检够得着）。
//
// 这里只收 CC-BY / CC0（docs/plans/2026-09-22-audio-library.md）：CC-BY 要在成片的说明里署名，结果里带着署名句，
// 说明要求 AI 告诉用户。**音效库还没做**（App 里只有音乐）：工具说明里照实写，并叫 AI 别去网上下载。

@MainActor
enum AIAudioLibraryTools {
    /// 等音乐清单读好（网上的，断网用上次的缓存），最多 15 秒。上次没读到就再读一次
    ///（`loadIfNeeded` 只在还没读过时读，失败之后不会自己重试）。
    static func musicItems() async throws -> [AudioLibraryItem] {
        let store = AudioLibraryStore.music
        if case .failed = store.state { store.reload() } else { store.loadIfNeeded() }
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            switch store.state {
            case .loaded(let items):
                return items
            case .failed(let message):
                throw AIToolError("SrtFlow's music library could not be loaded: \(message)")
            case .idle, .loading:
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        throw AIToolError("SrtFlow's music library is still loading. Try again in a moment.")
    }

    static func findAudio(_ args: AIToolArguments) async throws -> AIToolResult {
        let query = try args.string("query") ?? ""
        let limit = min(max(try args.int("max_results") ?? 10, 1), 50)
        let items = try await musicItems()
        let matched = AudioLibraryManifest.filter(items, query: query)
        let cached = AudioLibraryCache.shared.cachedIDs
        var result: [String: JSONValue] = [
            "matched": .number(Double(matched.count)),
            "tracks": .array(matched.prefix(limit).map { AIMusicCredits.describe($0, downloaded: cached.contains($0.id)) }),
            "note": .string(
                "Add a track with add_clips {\"library_id\": id}. CC-BY tracks must be credited: tell the user to put the "
                + "credit line in the video's description."
            )
        ]
        if AudioLibraryStore.music.isStale { result["offline"] = "SrtFlow is offline and showing the last known list." }
        return .ok(.object(result))
    }

    /// get_timeline 用：工程里用到的音乐库素材的署名句。清单还没读好就先不写（顺手让它开始读，下次就有）。
    static func projectCredits(_ state: TimelineState) -> [String] {
        let keys = Set(state.allClips.compactMap(\.remoteKey))
        guard !keys.isEmpty else { return [] }
        let items = AudioLibraryStore.music.state.items
        if items.isEmpty { AudioLibraryStore.music.loadIfNeeded() }
        return AIMusicCredits.lines(items.filter { keys.contains($0.id) })
    }

    /// add_clips 的 library_id：下载（缓存里有就直接用），做成和从音频库拖进来一样的片段（带 `remoteKey`，时长按清单）。
    static func libraryClip(id: String) async throws -> (clip: EditClip, item: AudioLibraryItem) {
        let items = try await musicItems()
        guard let item = items.first(where: { $0.id == id }) else {
            throw AIToolError("There is no track \(id) in SrtFlow's music library. Use find_audio for ids.")
        }
        let url: URL
        do {
            url = try await AudioLibraryCache.shared.download(item)
        } catch {
            throw AIToolError("SrtFlow could not download \(item.title): \(error.localizedDescription)")
        }
        let clip = EditClip(
            sourceURL: url, isAudioOnly: true, sourceDuration: item.duration,
            audioAssetDuration: item.duration, remoteKey: item.id
        )
        return (clip, item)
    }
}
