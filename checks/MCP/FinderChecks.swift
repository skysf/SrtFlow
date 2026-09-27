import Foundation

// open_folder from_finder（AIFinderSelection）：选了一个文件夹就点名它、全列；选了几个文件就登记它们共同的上级、
// 只列选中的；osascript 的输出一行一个路径；用户没允许控制访达（-1743）时告诉 AI 去哪儿开。
// 真问访达要图形会话和一次授权，靠人工回归清单。编法见 scripts/check-mcp.sh。

func runFinderChecks() {
    let folder = URL(fileURLWithPath: "/tmp/srtflow-finder/素材")
    let isDirectory: (URL) -> Bool = { $0.pathExtension.isEmpty }

    let single = AIFinderSelection.workspace(for: [folder], isDirectory: isDirectory)
    checkEqual(single.folder.path, folder.path, "one selected folder is the workspace")
    check(single.only == nil, "one selected folder: list everything in it")

    let clips = [folder.appendingPathComponent("A/企鹅.mp4"), folder.appendingPathComponent("B/船.mp4")]
    let files = AIFinderSelection.workspace(for: clips, isDirectory: isDirectory)
    checkEqual(files.folder.path, folder.path, "selected files: their common folder is the workspace")
    checkEqual(files.only?.count, 2, "selected files: only those are listed")
    check(AIFinderSelection.isSelected(clips[0], among: clips), "a selected file is listed")
    check(!AIFinderSelection.isSelected(folder.appendingPathComponent("A/鲸鱼.mp4"), among: clips),
          "a file next to it that was not selected is not listed")
    check(AIFinderSelection.isSelected(folder.appendingPathComponent("Shots/1.mp4"), among: [folder.appendingPathComponent("Shots")]),
          "files inside a selected folder are listed")

    checkEqual(AIFinderSelection.paths(from: "/a/b.mp4\n\n/c d/e.mov\n").map(\.path), ["/a/b.mp4", "/c d/e.mov"],
               "one path per line, blank lines skipped, spaces kept")
    check(AIFinderSelection.explain(status: 1, error: "execution error: Not authorized to send Apple events to Finder. (-1743)")
            .contains("Privacy & Security > Automation"), "a refused permission tells the AI where the user can allow it")
}
