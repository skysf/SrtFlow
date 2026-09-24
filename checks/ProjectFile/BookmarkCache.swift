import Darwin
import Foundation

// 第 30 组：素材书签的会话缓存（`MediaBookmarkCache`）。编译方式见 scripts/check-project-file.sh。
//
// 1. 同一个文件：书签只建一次，之后原样复用 —— 自动保存每次都重建的话，57 个素材的工程
//    每次存盘主线程卡约 55ms（2026-09-24 实测）。`MediaRecord` 走的也是它。
// 2. 路径上换成了别的文件（新 inode）：必须重建。不重建的话，以后这个文件被挪走时书签会把
//    工程指回旧文件。
// 3. 文件不在：返回 nil，交给调用方拿上次存的兜底。

func checkMediaBookmarkCache(root: URL) throws {
    let dir = root.appendingPathComponent("bookmarks")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("clip.mp4")
    try Data("first file".utf8).write(to: file)

    let before = MediaBookmarkCache.creations
    let first = MediaRecord(url: file, projectDirectory: dir).bookmark
    let again = MediaRecord(url: file, projectDirectory: dir).bookmark
    check(first != nil, "在的文件要建得出书签")
    checkEqual(MediaBookmarkCache.creations - before, 1, "同一个文件连存两次，书签只建一次")
    check(first == again, "同一个文件复用同一份书签")

    // 换成别的文件：写在旁边再 rename 盖过去 —— 路径不变、inode 变了。
    let replacement = dir.appendingPathComponent("clip.tmp")
    try Data("second, a different file".utf8).write(to: replacement)
    check(rename(replacement.path, file.path) == 0, "rename 盖过去（造一个新 inode）")
    let renewed = MediaRecord(url: file, projectDirectory: dir).bookmark
    checkEqual(MediaBookmarkCache.creations - before, 2, "路径上换了文件（新 inode）就得重建书签")
    check(renewed != nil && renewed != first, "换了文件之后的书签不能还是旧文件那份")

    // 文件不在：缓存不给，MediaRecord 拿上次存的兜底。
    try FileManager.default.removeItem(at: file)
    check(MediaBookmarkCache.bookmark(for: file) == nil, "文件不在就返回 nil")
    let previous = MediaRecord(url: file, projectDirectory: dir, previous: nil)
    var withOld = previous
    withOld.bookmark = renewed
    checkEqual(MediaRecord(url: file, projectDirectory: dir, previous: withOld).bookmark, renewed,
               "文件不在时沿用上次存的书签（旧记录只能补，不能覆盖成 nil）")
}
