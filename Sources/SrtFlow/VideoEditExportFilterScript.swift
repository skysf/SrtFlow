import Foundation

// MARK: - 导出：滤镜图怎么交给 ffmpeg
//
// 原来和声音的 `aeval` 增益树住在一个文件里（VideoEditExportAudioGain.swift）。2026-09-24 成片的
// 声音改成离线读预览混音（ExportAudioMixdown）之后，增益树整个退役，只剩下这一件和声音无关的事。
//
// 故意是一个**类型**而不是 `VideoEditExportGraph` 的扩展：自检脚本的源文件清单守卫只认得
// 「引用了别的文件里的顶层类型」，只有扩展的文件漏编了它看不出来
//（checks/check-script-source-lists.sh 写明的盲区）。

enum ExportFilterScript {
    /// 滤镜图的传法：平常照旧是一个命令行参数；超过 `argumentLimit` 就写进工作目录
    /// 的文件、用 `-/filter_complex <文件>` 传（ffmpeg 7 起的写法）。
    ///
    /// macOS 的 ARG_MAX 是 1MB，而且整条命令行（加上环境变量）共用这一份 —— 文字、形状、
    /// 上层轨多的工程，滤镜图攒起来能顶到。文本和参数形式逐字相同。
    static func arguments(_ graph: String, workspace: URL) throws -> [String] {
        guard graph.utf8.count > argumentLimit else { return ["-filter_complex", graph] }
        let file = workspace.appendingPathComponent("filter-graph.txt")
        try graph.write(to: file, atomically: true, encoding: .utf8)
        return ["-/filter_complex", file.path]
    }

    /// 超过这个字节数就改走文件（离 1MB 的 ARG_MAX 留足余量给素材路径和环境变量）。
    static let argumentLimit = 256 * 1024
}
