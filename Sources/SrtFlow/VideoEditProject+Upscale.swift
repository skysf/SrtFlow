import Foundation

// MARK: - 工程上的换源：把段换成 upscale 文件、换回原片
//
// 管什么：第三刀的任务做完、用户在对比窗口里点了「替换」之后，这个工程里用同一个原片的画面段一起换源（一次 perform 一步撤销，
// 范围被新文件盖住的才换）；右键「换回原片」把一段换回去（原片挪了按书签找，找不到就不换）。规则本身在 VideoEditClipUpscale.swift。
// 查到 fal 实收之后把钱补进记录（`recordUpscaleCost`：不进撤销栈、不重建预览、标脏存盘）。
// 不管什么：文件怎么做出来、进度、界面；换源之后预览重建（`perform` 收尾的 `scheduleRebuild` 管）。

extension VideoEditProject {
    /// 这个工程里用这个原片的画面段（此刻直接用着它的，和已经换成它的 upscale 文件的）。
    func clipIDs(usingPicture url: URL) -> [UUID] { state.clipIDs(usingPicture: url) }

    /// 换源：`ids` 里范围被新文件盖住的段一起换，一步撤销。返回换了的段。
    @discardableResult
    func applyUpscale(_ replacement: ClipSourceSwap.Replacement, to ids: [UUID]) -> [UUID] {
        var done: [UUID] = []
        perform { state in done = state.applyUpscale(replacement, to: ids) }
        return done
    }

    /// 账单查到实收之后把钱补进工程里的记录（做完几分钟后才有）：不进撤销栈、不重建预览，算工程的改动（存盘）。
    /// 换源那一步可能早就做完了（AI 起的做完就换；面板起的用户点 Replace 也常在查到之前），所以回写要按文件找此刻用着它的段。
    func recordUpscaleCost(file: URL, costUSD: Double) {
        applyDocumentRepair(annotation: true) { state in state.recordUpscaleCost(file: file, costUSD: costUSD) }
    }

    /// 原片此刻在哪：没动过就是记录里的路径；改名 / 挪了按存盘时配的书签找；找不到 = nil（菜单灰掉）。
    func upscaleOriginalURL(for clipID: UUID) -> URL? {
        guard let record = state.allClips.first(where: { $0.id == clipID })?.upscale else { return nil }
        if FileManager.default.fileExists(atPath: record.originalURL.path) { return record.originalURL }
        let outcome = VideoEditProjectIO.relocateMedia(
            urls: [record.originalURL], records: mediaRecords, projectDirectory: documentURL?.deletingLastPathComponent()
        )
        return outcome.moved[record.originalURL]
    }

    /// 换回原片。原片挪了先把记录里的路径改成找到的那一处，再换回去；找不到就什么都不做。
    @discardableResult
    func revertUpscale(_ clipID: UUID) -> Bool {
        guard let found = upscaleOriginalURL(for: clipID) else { return false }
        var done: [UUID] = []
        perform { state in
            if let record = state.allClips.first(where: { $0.id == clipID })?.upscale, record.originalURL != found {
                state.replaceMedia(record.originalURL, with: found)
            }
            done = state.revertUpscale([clipID])
        }
        return !done.isEmpty
    }
}
