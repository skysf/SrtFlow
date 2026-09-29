import Foundation

// MARK: - 导出图里的调色（lut3d）
//
// 管什么：把时间轴上的滤镜段（`renderedFilters`）翻成导出滤镜图里的 `format=gbrp` + 一串 `lut3d`，落点、顺序和三条对齐约束。
// 不管什么：LUT 的数学和 .cube 的写法（`FilterLUT`）、预览侧怎么挂（`FilterStack`）、别的滤镜图步骤（`VideoEditExportGraph`）。
// 2026-09-30 从 VideoEditExportGraph.swift 原样搬出来（那个文件在行数基线里只许降，接「盖一块」要腾地方）。

enum VideoEditGradeExport {

    /// 落点是**画面合成之后、盖一块和形状之前**：滤镜染的是这一段时间里的全部画面
    ///（主轨 + 上层轨），不染形状/文字/字幕。这和预览侧「滤镜挂在播放器视图
    /// 上、叠层是它上面的兄弟视图」一字不差 —— 两处的层序必须同一个说法。
    ///
    /// 三条和预览对齐的硬约束（改这里之前先读 docs/architecture/filters.md）：
    ///
    /// 1. **顺序按 `orderedFilters`**（层号小的先作用）。LUT 不可交换，两条
    ///    管线各排各的就是「预览一个味道、成片另一个味道」。
    /// 2. **`interp=trilinear` 必须显式写**。lut3d 默认是 tetrahedral，而预览
    ///    侧的 CIColorCube 是三线性；不写这一项，同一张表两边算出来就不一样。
    /// 3. **`format=gbrp` 垫在前面**。不指定的话滤镜图会自己协商像素格式，
    ///    万一谈成 YUV，这张 RGB 查找表会被当成对 Y/U/V 查表用 —— 画面直接
    ///    烂掉。显式压成 8bit 平面 RGB，定义域和预览一致。
    ///
    /// 强度 0 的段整条跳过：那是「先关掉看看」，成片应当和原片逐像素相同，
    /// 而不是白跑一遍恒等表（预览侧 `FilterStack` 有同一条短路）。
    static func append(
        _ state: TimelineState, total: Double, workspace: URL,
        video: inout String, filters: inout [String], nextLabel: (String) -> String
    ) throws {
        let gradeFilters = state.renderedFilters.filter {  // 按 orderedFilters 的顺序、藏起来的不算
            $0.strength > 0.0005 && $0.timelineEnd > 0 && $0.timelineStart < total
        }
        guard !gradeFilters.isEmpty else { return }
        let rgb = nextLabel("v")
        filters.append("[\(video)]format=gbrp[\(rgb)]")
        video = rgb
        for (index, grade) in gradeFilters.enumerated() {
            let filename = "filter\(index).cube"
            try FilterLUT.cubeFileText(for: grade.preset, strength: grade.strength)
                .write(
                    to: workspace.appendingPathComponent(filename),
                    atomically: true, encoding: .utf8
                )
            let outV = nextLabel("v")
            filters.append(
                "[\(video)]lut3d=file=\(filename):interp=trilinear:" +
                "enable='between(t,\(VideoEditExportGraph.fmt(max(0, grade.timelineStart))),\(VideoEditExportGraph.fmt(min(total, grade.timelineEnd))))'" +
                "[\(outV)]"
            )
            video = outV
        }
    }
}
