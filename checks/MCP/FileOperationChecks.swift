import Foundation

// manage_files（整理文件，AIFileOperations）：只在点名的文件夹里动、不覆盖、改名保留后缀、不许挪进自己里面，
// 以及在临时目录里真做一遍（移动、改名、建文件夹、进废纸篓 —— 废纸篓里那份测完就删，不在用户的废纸篓里留东西）。
// 编法见 scripts/check-mcp.sh；规矩见 docs/plans/2026-09-27-mcp.md 第 21、23、24 条。

func runFileOperationChecks() {
    checkFilePlans()
    checkFileOperationsOnDisk()
}

private func checkFilePlans() {
    let root = URL(fileURLWithPath: "/tmp/srtflow-files-plan/南极")
    let shot = root.appendingPathComponent("Shots/企鹅.mp4")
    let other = URL(fileURLWithPath: "/tmp/elsewhere/a.mp4")
    let existing: Set<String> = [shot.path, root.appendingPathComponent("Shots/船.mp4").path,
                                 root.appendingPathComponent("精选/企鹅.mp4").path, other.path]
    let exists: (URL) -> Bool = { existing.contains($0.standardizedFileURL.path) }
    func plan(_ action: AIFileOperations.Action, _ sources: [URL], to: URL? = nil, name: String? = nil) throws -> [AIFileOperations.Step] {
        try AIFileOperations.plan(action, sources: sources, to: to, newName: name, roots: [root], exists: exists)
    }

    checkThrows("nothing outside the named folders is touched") { _ = try plan(.trash, [other]) }
    checkThrows("no folder named yet: refuse") {
        _ = try AIFileOperations.plan(.trash, sources: [shot], to: nil, newName: nil, roots: [], exists: exists)
    }
    checkThrows("moving onto a file that is already there is refused (no overwrite)") {
        _ = try plan(.move, [shot], to: root.appendingPathComponent("精选"))
    }
    checkThrows("moving out of the named folder is refused") { _ = try plan(.move, [shot], to: URL(fileURLWithPath: "/tmp")) }
    checkThrows("a folder cannot go into itself") {
        _ = try plan(.move, [root.appendingPathComponent("Shots")], to: root.appendingPathComponent("Shots/sub"))
    }
    checkThrows("a new name with a folder in it is refused") { _ = try plan(.rename, [shot], name: "a/b") }
    checkThrows("renaming onto a taken name is refused") { _ = try plan(.rename, [shot], name: "船") }

    let renamed = try? plan(.rename, [shot], name: "开场")
    checkEqual(renamed?.first?.destination?.lastPathComponent, "开场.mp4", "a new name without an extension keeps the old one")
    let moved = try? plan(.move, [shot], to: root.appendingPathComponent("精选/企鹅"))
    checkEqual(moved?.first?.destination?.path, root.appendingPathComponent("精选/企鹅/企鹅.mp4").path, "move keeps the file name")
    checkEqual((try? plan(.trash, [shot]))?.count, 1, "trash plans one step per file")
    check(AIFileOperations.isInside(shot, roots: [root]) && !AIFileOperations.isInside(root, roots: [root]),
          "inside means below the folder, not the folder itself")
}

private func checkFileOperationsOnDisk() {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent("srtflow-files-\(getpid())")
    try? manager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: root) }
    let clip = root.appendingPathComponent("clip.mp4")
    let junk = root.appendingPathComponent("junk.tmp")
    try? Data("x".utf8).write(to: clip)
    try? Data("y".utf8).write(to: junk)
    let exists: (URL) -> Bool = { manager.fileExists(atPath: $0.path) }

    let folder = root.appendingPathComponent("精选")
    if let steps = try? AIFileOperations.plan(.makeFolder, sources: [], to: folder, newName: nil, roots: [root], exists: exists) {
        checkEqual(AIFileOperations.perform(steps, action: .makeFolder).error, nil, "make_folder works")
    }
    if let steps = try? AIFileOperations.plan(.move, sources: [clip], to: folder, newName: nil, roots: [root], exists: exists) {
        _ = AIFileOperations.perform(steps, action: .move)
    }
    let movedClip = folder.appendingPathComponent("clip.mp4")
    check(exists(movedClip) && !exists(clip), "move puts the file in the folder")
    if let steps = try? AIFileOperations.plan(.rename, sources: [movedClip], to: nil, newName: "opening", roots: [root], exists: exists) {
        _ = AIFileOperations.perform(steps, action: .rename)
    }
    check(exists(folder.appendingPathComponent("opening.mp4")), "rename keeps the extension on disk")

    guard let steps = try? AIFileOperations.plan(.trash, sources: [junk], to: nil, newName: nil, roots: [root], exists: exists) else {
        check(false, "trash plan failed")
        return
    }
    let outcome = AIFileOperations.perform(steps, action: .trash)
    check(!exists(junk), "trash removes the file from the folder (\(outcome.error ?? "no error"))")
    if let inTrash = outcome.done.first?.destination {
        check(exists(inTrash), "the trashed file is in the Trash, recoverable")
        try? manager.removeItem(at: inTrash)
    } else {
        check(false, "trash did not report where the file went")
    }
}
