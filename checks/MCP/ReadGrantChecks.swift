import Foundation

// 点名文件夹以外的文件：问一次，记住那个文件夹（AIReadGrants，方案第 34 条）。记的是文件所在的文件夹；
// 那个文件夹太大（根目录、顶层文件夹、卷的根、个人文件夹本身）时只记这个文件；子文件夹算在里面、名字相像的兄弟不算。
// 编法见 scripts/check-mcp.sh。

func runReadGrantChecks() {
    let home = URL(fileURLWithPath: "/Users/me")
    func grant(_ path: String) -> String { AIReadGrants.grant(for: URL(fileURLWithPath: path), home: home) }
    checkEqual(grant("/Users/me/Movies/trip/a.mp4"), "/Users/me/Movies/trip", "a file's folder is remembered")
    checkEqual(grant("/Users/me/Movies/trip/../b.mp4"), "/Users/me/Movies", "paths are standardized first")
    checkEqual(grant("/Users/me/a.mp4"), "/Users/me/a.mp4", "right in the home folder: only that file")
    checkEqual(grant("/tmp/a.srt"), "/tmp/a.srt", "a top-level folder: only that file")
    checkEqual(grant("/a.mp4"), "/a.mp4", "the disk's root: only that file")
    checkEqual(grant("/Volumes/Card/clip.mov"), "/Volumes/Card/clip.mov", "a card's root: only that file")
    checkEqual(grant("/Volumes/Card/DCIM/clip.mov"), "/Volumes/Card/DCIM", "a folder on a card is fine")

    check(AIReadGrants.covers("/Users/me/Movies/trip/b/c.mp4", grants: ["/Users/me/Movies/trip"]), "subfolders are covered")
    check(!AIReadGrants.covers("/Users/me/Movies/trip2/c.mp4", grants: ["/Users/me/Movies/trip"]),
          "a sibling whose name starts the same is not")
    check(AIReadGrants.covers("/Users/me/a.mp4", grants: ["/Users/me/a.mp4"]), "a remembered file")
    check(!AIReadGrants.covers("/Users/me/b.mp4", grants: ["/Users/me/a.mp4"]), "…only that file")

    checkEqual(AIReadGrants.adding([URL(fileURLWithPath: "/Users/me/Movies/a.mp4")],
                                   to: ["/Users/me/Movies/trip", "/Users/me/Music"], home: home),
               ["/Users/me/Movies", "/Users/me/Music"], "a wider folder replaces the ones inside it")
    checkEqual(AIReadGrants.adding([URL(fileURLWithPath: "/Users/me/Movies/trip/x/a.mp4")], to: ["/Users/me/Movies"], home: home),
               ["/Users/me/Movies"], "already covered: nothing new")
    checkEqual(AIReadGrants.adding([URL(fileURLWithPath: "/Users/me/a.mp4"), URL(fileURLWithPath: "/Users/me/Movies/b.mp4")],
                                   to: [], home: home),
               ["/Users/me/Movies", "/Users/me/a.mp4"], "several at once, sorted")
}
