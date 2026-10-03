import Foundation

// 形状：预览画的和成片一样，入场 / 出场动画落在对的帧上（2026-10-03，docs/architecture/shapes.md）。
//
// 一、预览那个画法（`ShapePreviewDrawing`，离屏渲一张）和导出那张（`ShapePNGRenderer`）逐像素比（Parity.swift）：
//    五种形状 × 描边 / 实心 × 不动 / 画到一半 / 擦除 / 缩放 / 半透明。两边的路径都来自 `ShapeOutline`，比的是上色那一层
//    有没有各写各的（线头、裁剪、透明度）—— 2026-10-03 之前线条就是各画一份，导出的线两头各比预览长半个线宽。
// 二、真跑一遍导出（`VideoEditExportGraph.plan` + ffmpeg）抽帧（Export.swift）：入场画到一半、中间整个、出场淡到一半、
//    段外没有；只逐帧渲动画那两截（数工作目录里的 PNG）；没有动画的形状照旧一张图。
// 编法见 scripts/check-shape-render.sh。

var failures = 0
var checks = 0

func check(_ condition: Bool, _ message: String, file: String = #fileID, line: Int = #line) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL [\(file):\(line)] \(message)")
    }
}

let ffmpegPath = ProcessInfo.processInfo.environment["SRTFLOW_FFMPEG"]
    ?? FileManager.default.currentDirectoryPath + "/vendor/ffmpeg"

let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("srtflow-shaperender-\(UUID().uuidString)", isDirectory: true)
try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

func finish(_ code: Int32) -> Never {
    try? FileManager.default.removeItem(at: root)
    exit(code)
}

await runParityChecks()
await runExportChecks()
print("\(checks - failures)/\(checks) 通过")
finish(failures == 0 ? 0 : 1)
