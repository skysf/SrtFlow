import Foundation

// 音频库的清单来源。产品口径见 docs/plans/2026-09-22-audio-library.md。
//
// **清单本身也要缓存。** 没网时素材下过的还能用（文件在本地），但清单拉不到的话
// 整个面板会是空的 —— 用户看到的是「我的音乐库没了」，而不是「现在没网」。
// 所以每次成功拉取都留一份到本地，离线时用它，并在界面上标明这是离线清单。
//
// 拉取地址来自 `AudioLibrarySource`，不是写死的常量：以后从公开域名换到 Worker
// 网关只要改这一处（plan 第四节第 1 条的另一半 —— 素材 URL 由 manifest 给，
// 清单 URL 由这里给）。

/// 一个库（音乐 / 音效各一个）。
struct AudioLibrarySource: Sendable {
    var kind: AudioLibraryItem.Kind
    var manifestURL: URL

    static let music = AudioLibrarySource(
        kind: .music,
        manifestURL: URL(string: "https://downloads.skylu.ai/Audio/Music/manifest.json")!
    )
    static let soundEffects = AudioLibrarySource(
        kind: .sfx,
        manifestURL: URL(string: "https://downloads.skylu.ai/Audio/SoundEffects/manifest.json")!
    )
}

@MainActor
final class AudioLibraryStore: ObservableObject {
    static let music = AudioLibraryStore(source: .music)

    @Published private(set) var state: State = .idle
    /// 这份清单是从本地缓存读的（拉取失败时的退路），界面要标出来。
    @Published private(set) var isStale = false

    let source: AudioLibrarySource
    private var loadTask: Task<Void, Never>?

    init(source: AudioLibrarySource) {
        self.source = source
    }

    enum State {
        case idle
        case loading
        case loaded([AudioLibraryItem])
        case failed(String)

        var items: [AudioLibraryItem] {
            if case .loaded(let items) = self { return items }
            return []
        }
    }

    /// 打开面板时调。已经有内容就不重复拉 —— 常驻面板每次切页都重拉是浪费。
    func loadIfNeeded() {
        guard case .idle = state else { return }
        reload()
    }

    func reload() {
        loadTask?.cancel()
        state = .loading
        loadTask = Task { [source] in
            do {
                var request = URLRequest(url: source.manifestURL)
                // 清单会变（扩库），但不该每次开面板都真的走一趟网络。
                request.cachePolicy = .useProtocolCachePolicy
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw AudioLibraryCache.DownloadError.http(http.statusCode)
                }
                let manifest = try AudioLibraryManifest.parse(data)
                guard !Task.isCancelled else { return }
                try? saveCachedManifest(data)
                isStale = false
                state = .loaded(manifest.items)
            } catch {
                guard !Task.isCancelled else { return }
                // 拉不到就用上一次的。**版本过高是例外** —— 那份清单本来就不是给
                // 这个 App 读的，退回旧缓存只会让用户看到一个永远缺新素材的库，
                // 还不知道为什么。这种情况直接把话说清楚。
                if case AudioLibraryManifest.ParseError.unsupportedVersion = error {
                    state = .failed(error.localizedDescription)
                    return
                }
                if let cached = loadCachedManifest(),
                   let manifest = try? AudioLibraryManifest.parse(cached) {
                    isStale = true
                    state = .loaded(manifest.items)
                } else {
                    state = .failed(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - 清单的本地副本

    private var cacheURL: URL {
        AudioLibraryCache.shared.directory
            .appendingPathComponent("manifest-\(source.kind.rawValue).json")
    }

    private func saveCachedManifest(_ data: Data) throws {
        try FileManager.default.createDirectory(
            at: AudioLibraryCache.shared.directory, withIntermediateDirectories: true)
        try data.write(to: cacheURL, options: .atomic)
    }

    private func loadCachedManifest() -> Data? {
        try? Data(contentsOf: cacheURL)
    }
}
