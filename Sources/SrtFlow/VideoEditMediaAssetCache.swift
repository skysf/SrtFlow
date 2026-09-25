import AVFoundation
import Darwin
import Foundation
import os

// MARK: - 素材的进程级缓存
//
// 管什么：预览重建时用到的 `AVURLAsset`，按「路径 + 文件身份」在这次会话里只开一次。
// 不管什么：合成怎么搭（`VideoEditCompositionBuilder`）、素材挪走了怎么重链接
//（`revalidateMediaLocations`，它在每次重建前跑，路径变了这里的键也就跟着变了）。
//
// 为什么（docs/bugfixes/2026-09-25-rebuild-reopens-every-asset.md）：每次松手重建预览，builder
// 都把工程里每个文件重新 `AVURLAsset(url:)` + `loadTracks`，文件头逐个重新解析 —— 用户 77 段的
// 工程一次松手开 63 次。`AVAsset` 自己会缓存已经载入的属性，实例留着，第二次 `loadTracks` 立刻
// 返回；合成只是引用它的轨，不改它。
//
// 什么时候必须重开：路径上换成了别的文件（删了又放回一个同名的、先写临时文件再改名盖过来），
// inode / 卷就不一样了 —— 这一半和 `MediaBookmarkCache` 同一个认法；**原地改写**（`ffmpeg -y` 往同一个
// 输出路径写：截断重写，inode 不变）还得靠大小和修改时间认出来 —— 书签跟着 inode 走，原地改写
// 不影响它，可缓存的 asset 已经读过旧的文件头，接着用会按旧的采样表去读新内容。所以这里比书签
// 多认两样：大小、修改时间（纳秒）。路径不存在（stat 失败）就不缓存、照旧现开，builder 对加载
// 失败的段只能跳过，行为和以前一样。
//
// 容量：最多 `capacity` 个，超了丢最久没用的。`AVURLAsset` 不占着文件句柄，留着只是一点内存。

enum MediaAssetCache {
    /// 文件身份：换了文件（inode / 卷）或者原地改写过（大小 / 修改时间）都算另一个。
    private struct Identity: Equatable {
        var inode: UInt64
        var device: Int32
        var size: Int64
        var modifiedSeconds: Int
        var modifiedNanoseconds: Int

        init(_ info: stat) {
            inode = UInt64(info.st_ino)
            device = info.st_dev
            size = Int64(info.st_size)
            modifiedSeconds = info.st_mtimespec.tv_sec
            modifiedNanoseconds = info.st_mtimespec.tv_nsec
        }
    }

    private struct Entry {
        var identity: Identity
        var asset: AVURLAsset
        var lastUse: UInt64
    }

    private struct Store {
        var entries: [String: Entry] = [:]
        var tick: UInt64 = 0
        var created = 0
    }

    static let capacity = 256
    private static let store = OSAllocatedUnfairLock(initialState: Store())

    /// 这次会话里真开了几次文件。自检数它，确认「同一个文件只开一次、换了文件才重开」。
    static var creations: Int { store.withLockUnchecked { $0.created } }

    /// 这个文件此刻的 asset。`opened` = 这一次是不是真开了文件（性能计数用）。
    static func asset(for url: URL) -> (asset: AVURLAsset, opened: Bool) {
        var info = stat()
        guard stat(url.path, &info) == 0 else {
            // 文件不在：不缓存，现开一个让 builder 自己去失败（它会跳过这一段）。
            return (AVURLAsset(url: url), true)
        }
        let identity = Identity(info)
        return store.withLockUnchecked { store -> (AVURLAsset, Bool) in
            store.tick += 1
            if var cached = store.entries[url.path], cached.identity == identity {
                cached.lastUse = store.tick
                store.entries[url.path] = cached
                return (cached.asset, false)
            }
            let fresh = AVURLAsset(url: url)
            store.created += 1
            store.entries[url.path] = Entry(identity: identity, asset: fresh, lastUse: store.tick)
            if store.entries.count > capacity,
               let oldest = store.entries.min(by: { $0.value.lastUse < $1.value.lastUse }) {
                store.entries.removeValue(forKey: oldest.key)
            }
            return (fresh, true)
        }
    }

    /// 全部丢掉（自检在两个场景之间用；App 里不用 —— 文件身份变了自己会重开）。
    static func removeAll() {
        store.withLockUnchecked { $0.entries.removeAll() }
    }
}
