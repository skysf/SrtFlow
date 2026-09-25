import Darwin
import Foundation
import os

// MARK: - 素材书签的会话缓存
//
// 管什么：存盘时每个素材的系统书签（`MediaRecord.bookmark`）—— 同一个文件在这次会话里
// 建过就拿旧的，不再每次自动保存都重建一遍。
// 不管什么：书签怎么解、素材怎么重链接（VideoEditProjectFile.swift 的四层线索）。
//
// 为什么：建书签很贵，系统要去查 LaunchServices 的隔离属性。2026-09-24 在用户 57 个素材的
// 工程上实测：一次自动保存在主线程上花约 55ms，几乎全在建书签 —— 而自动保存是每改一下、
// 停 2 秒就来一次，改得勤就隔一会儿卡一下。
//
// 什么时候必须重建：书签记的是 inode + 卷，所以**只要这个路径上还是同一个 inode**，旧书签
// 就还是对的；路径上换成了别的文件（重新导出盖掉了、删了又放回一个同名的），就得重建 ——
// 不然以后这个文件被挪走时，书签会把工程指回旧的那个（比如废纸篓里那份）。所以缓存按
// 「路径 + inode + 卷」认，变了一样就重建。

enum MediaBookmarkCache {
    private struct Entry {
        var inode: UInt64
        var device: Int32
        var bookmark: Data
    }

    private static let entries = OSAllocatedUnfairLock(initialState: [String: Entry]())
    private static let created = OSAllocatedUnfairLock(initialState: 0)

    /// 这次会话里实际建了几个书签。自检数它，确认「同一个文件只建一次」。
    static var creations: Int { created.withLock { $0 } }

    /// 这个文件此刻的书签。文件不在（读不到 inode）或者建不出来就返回 nil ——
    /// 由调用方拿上次存的那份兜底（`MediaRecord` 的「旧记录只能补，不能覆盖成 nil」）。
    static func bookmark(for url: URL) -> Data? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        let inode = UInt64(info.st_ino)
        let device = info.st_dev
        if let cached = entries.withLock({ $0[url.path] }), cached.inode == inode, cached.device == device {
            return cached.bookmark
        }
        guard let fresh = try? url.bookmarkData(
            options: [], includingResourceValuesForKeys: nil, relativeTo: nil
        ) else { return nil }
        created.withLock { $0 += 1 }
        entries.withLock { $0[url.path] = Entry(inode: inode, device: device, bookmark: fresh) }
        return fresh
    }
}
