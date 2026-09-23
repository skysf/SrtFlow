import Foundation

// MARK: - 导出：一段声音的增益步骤（音量 / 音量曲线 / 推子）
//
// 从 `VideoEditExportGraph.swift` 旁边单开（那个文件已经过了 800 行）。
//
// 两种形态，都已经乘好了轨道推子 × 总推子：
//
// - 没画曲线：`volume=<常数>`。推子都在 0 dB 时字面上和以前一模一样（`fmt` 那种
//   三位小数），老工程的导出参数一个字节不变。
// - 画了曲线：`aeval`，逐样本求一棵**平衡的 if 树**，叶子是折线表里每一段的
//   一次式 `(a+b*t)`。折线表就是预览 `setVolumeRamp` 用的那一张
//   （`VolumeCurveSampling.breakpoints`），所以两条管线是同一条折线。
//
// 2026-09-23 用 ffmpeg 8.1 实测过的几条（探针在 docs/architecture/audio-volume-curve.md）：
//
// 1. **放在 `adelay` 之前**：`adelay` 垫的那段静音没有时间戳，`aeval` 在那里读到的
//    `t` 是 NaN 或垃圾值。下面这棵树在 NaN 下每一层都走右边、落在最右那片**常数**
//    叶子上，所以不至于算出 nan（2026-09-23 反向验证过：挪到后面也没出 nan）——
//    但那是树的形状碰巧兜住了，不是设计。放在前面、自己减掉首帧定格那一截
//    （`renderHoldHead`），时间零点才是确定的。**最右叶子必须保持常数**。
// 2. `t` 在 `asetpts=PTS-STARTPTS,atempo…` 之后从 0 起、按**输出**时间走（即时间线
//    秒），与 `afade` 同一个前提。
// 3. `if` 是惰性求值：平衡树的代价随 log N 涨（N=4000 时 48 秒立体声多花 0.85 秒）；
//    写成「各段相加」是线性的，N=1000 要多花几分钟。表达式嵌套深过约 100 层 ffmpeg
//    直接拒绝，平衡树的深度是 log2(N)+几层，远在限额以内。
// 4. 数字要**全精度**：`fmt` 只留三位小数，量到 0.02–0.04 的增益误差。
// 5. 表达式整个包在单引号里，逗号不用转义；里面不许出现 `:` 和 `|`（曲线用不到）。

/// 故意是一个**类型**而不是 `VideoEditExportGraph` 的扩展：自检脚本的源文件清单守卫
/// 只认得「引用了别的文件里的顶层类型」，只有扩展的文件漏编了它看不出来
///（checks/check-script-source-lists.sh 写明的盲区）。
enum ExportAudioGain {
    /// 一段声音的增益步骤，逗号结尾。
    ///
    /// - Parameters:
    ///   - gainScale: 轨道推子 × 总推子（线性）。
    ///   - timeOffset: 这一步前面、链上的时间零点离段起点多远（时间线秒）。只有主轨
    ///     的首帧定格那一截要减（定格垫在后面，`aeval` 看到的第 0 秒其实是段的
    ///     第 `renderHoldHead` 秒）。
    static func gainSteps(for clip: EditClip, gainScale: Double, timeOffset: Double = 0) -> String {
        guard clip.hasVolumeCurve else {
            // 推子都在 0 dB 时沿用原来的写法：老工程的参数逐字节不变。
            let value = gainScale == 1
                ? VideoEditExportGraph.fmt(clip.volume)
                : exactNumber(clip.volume * gainScale)
            return "volume=\(value),"
        }
        let points = VolumeCurveSampling.breakpoints(for: clip).map {
            VolumeCurveSampling.Breakpoint(time: $0.time - timeOffset, gain: $0.gain * gainScale)
        }
        return "aeval=exprs='val(ch)*(\(curveExpression(points)))':c=same,"
    }

    /// 折线表 → ffmpeg 表达式（变量 `t` 是离段起点的时间线秒）。
    ///
    /// 叶子依次是：第一个点之前的常数、每一段的一次式、最后一个点之后的常数；
    /// 相邻叶子之间的分界就是折点的时刻。零长度的段（两个点重合）直接跳过 ——
    /// 它不占任何样本，而 0 做分母会算出 inf。
    static func curveExpression(_ points: [VolumeCurveSampling.Breakpoint]) -> String {
        guard let first = points.first, let last = points.last else { return "1" }
        var leaves = ["(\(exactNumber(first.gain)))"]
        var boundaries = [first.time]
        for (a, b) in zip(points, points.dropFirst()) where b.time - a.time > 1e-9 {
            let slope = (b.gain - a.gain) / (b.time - a.time)
            let intercept = a.gain - slope * a.time
            leaves.append("(\(exactNumber(intercept))+\(exactNumber(slope))*t)")
            boundaries.append(b.time)
        }
        leaves.append("(\(exactNumber(last.gain)))")

        func build(_ low: Int, _ high: Int) -> String {
            if low == high { return leaves[low] }
            let mid = (low + high) / 2
            return "if(lt(t,\(exactNumber(boundaries[mid]))),\(build(low, mid)),\(build(mid + 1, high)))"
        }
        return build(0, leaves.count - 1)
    }

    /// 全精度的数字（Swift 的最短往返表示，`1e-05` 这种写法 ffmpeg 认）。
    /// 非有限值写 0：表达式里出现一个 nan，整段声音都会变成 nan。
    static func exactNumber(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return "\(value)"
    }

    /// 滤镜图的传法：平常照旧是一个命令行参数；超过 `argumentLimit` 就写进工作目录
    /// 的文件、用 `-/filter_complex <文件>` 传（ffmpeg 7 起的写法）。
    ///
    /// macOS 的 ARG_MAX 是 1MB，而且整条命令行（加上环境变量）共用这一份 ——
    /// 曲线多的工程每段一棵表达式树，攒起来能顶到。文本和参数形式逐字相同。
    static func filterComplexArguments(_ graph: String, workspace: URL) throws -> [String] {
        guard graph.utf8.count > argumentLimit else { return ["-filter_complex", graph] }
        let file = workspace.appendingPathComponent("filter-graph.txt")
        try graph.write(to: file, atomically: true, encoding: .utf8)
        return ["-/filter_complex", file.path]
    }

    /// 超过这个字节数就改走文件（离 1MB 的 ARG_MAX 留足余量给素材路径和环境变量）。
    static let argumentLimit = 256 * 1024
}
