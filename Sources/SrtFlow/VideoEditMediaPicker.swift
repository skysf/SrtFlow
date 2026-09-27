import SrtFlowCore
import UniformTypeIdentifiers

// MARK: - 剪辑页「加素材…」「加字幕文件…」弹的文件选择
//
// 管什么：弹系统的文件选择面板、把选中的文件交给工程（没有落点的那条老路 `addMedia`，
// 以及挂字幕的 `attachSubtitle`）。
// 不管什么：素材进时间线之后落在哪（VideoEditProject.addMedia）、拖进来的文件（MediaFileDrop）。
// 2026-09-27 从 VideoEditView.swift 挪出来（那个文件登记过超标、只许降）。

@MainActor
enum VideoEditMediaPicker {
    static func addMedia(to project: VideoEditProject, toOverlay: Bool) {
        var types = MediaFileTypes.video
        types.append(contentsOf: [.image, .png, .jpeg, .audio, .mp3, .mpeg4Audio, .wav])
        if !toOverlay {
            types.append(contentsOf: SubtitleFileTypes.readable)
        }
        let urls = FilePicker.chooseFiles(types: types)
        guard !urls.isEmpty else { return }
        project.addMedia(urls: urls, videosToOverlay: toOverlay)
    }

    static func addSubtitle(to project: VideoEditProject) {
        let urls = FilePicker.chooseFiles(types: SubtitleFileTypes.readable, allowsMultiple: false)
        guard let url = urls.first else { return }
        project.attachSubtitle(url)
    }
}
