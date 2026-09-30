import Foundation

// MARK: - 在两个库（音乐、音效）里找素材
//
// 管什么：等清单到手（网上的，断网用缓存；上次读失败就再读一次；最多等 15 秒）、把两个库的条目合在一起、按 id 找。
// 工程里存的 `remoteKey` 是清单的 id（音乐 mus_、音效 sfx_），但 App **不按前缀猜哪个库**，两份都读、都找：
// 重链接（VideoEditProjectDocument）、add_clips 的 library_id、署名句（AIAudioLibraryTools）都从这儿拿。
// 一个库读失败不拖累另一个：失败的话记在 `failures` 里，由调用方决定要不要说。
// 不管什么：清单怎么读、怎么缓存（AudioLibraryStore）、下载（AudioLibraryCache）。

@MainActor
enum AudioLibraryLookup {
    struct Loaded {
        var items: [AudioLibraryItem] = []
        /// 哪个库没读到、为什么（给 AI 或日志看的英文句子）。
        var failures: [String] = []
        /// 有哪个库是用上次的缓存顶着的。
        var stale = false
    }

    /// 等这几个库都读好或读失败，最多 `timeout` 秒；到点还在读的算失败。
    static func load(_ stores: [AudioLibraryStore], timeout: TimeInterval = 15) async -> Loaded {
        for store in stores {
            if case .failed = store.state { store.reload() } else { store.loadIfNeeded() }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            var loaded = Loaded()
            var waiting = false
            for store in stores {
                switch store.state {
                case .loaded(let items):
                    loaded.items += items
                    if store.isStale { loaded.stale = true }
                case .failed(let message):
                    loaded.failures.append("SrtFlow's \(name(of: store)) library could not be loaded: \(message)")
                case .idle, .loading:
                    waiting = true
                }
            }
            if !waiting { return loaded }
            if Date() >= deadline {
                for store in stores where !store.state.isSettled {
                    loaded.failures.append("SrtFlow's \(name(of: store)) library is still loading. Try again in a moment.")
                }
                return loaded
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    /// 已经读到的（不等）：get_timeline 写署名句用，没读到就顺手开始读、下次就有。
    static var loadedItems: [AudioLibraryItem] {
        var all: [AudioLibraryItem] = []
        for store in AudioLibraryStore.all {
            if store.state.items.isEmpty { store.loadIfNeeded() }
            all += store.state.items
        }
        return all
    }

    private static func name(of store: AudioLibraryStore) -> String {
        store.source.kind == .sfx ? "sound-effect" : "music"
    }
}

extension AudioLibraryStore.State {
    /// 读完了（成功或失败），不是还在路上。
    var isSettled: Bool {
        switch self {
        case .loaded, .failed: return true
        case .idle, .loading: return false
        }
    }
}
