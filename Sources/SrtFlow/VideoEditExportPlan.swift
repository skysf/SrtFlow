import Foundation

// MARK: - 导出图算出来的一份计划（纯值）
//
// 管什么：ffmpeg 的参数、工作目录、成片先落哪、是不是纯音频，以及混音的电平（封顶前的峰值、削了多久，
// ExportAudioMixdown.Levels）—— 导出面板和 AI 的导出结果拿它告诉用户「过 0 了，把主推子压下去」。
// 2026-09-30 从 VideoEditExportGraph 拆出来（那个文件只许降）。
// 不管什么：怎么算出来（VideoEditExportGraph.plan）、怎么跑（VideoEditExporter）。

extension VideoEditExportGraph {
    struct Plan {
        var arguments: [String]
        var workspace: URL
        var totalDuration: Double
        /// ffmpeg 实际写入的路径：workspace 里的临时文件，不是用户选的目标——
        /// 全部成功后才由调用方原子替换过去，失败/取消都不碰用户原有文件。
        var tempOutput: URL
        /// 一点画面都没有（只选了音频）：输出纯音频文件。
        var isAudioOnly = false
        /// 混音的电平；一个出声的段都没有时是 nil。
        var audioLevels: ExportAudioMixdown.Levels?
    }

    struct PlanError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }
}
