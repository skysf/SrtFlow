import CoreGraphics
import CoreImage
import Foundation

// 一款滤镜 = 一张 33³ 的查找表。表由 `FilterRecipe` 的解析式算出来，
// **预览和导出从同一个函数取同一份数据**：
//
//   预览 → `cubeData(...)`      → CIColorCubeWithColorSpace
//   导出 → `cubeFileText(...)`  → 写成 .cube 交给 ffmpeg 的 lut3d
//
// 两处都是先插值、后查表，所以「强度 70%」在两条管线里是同一个数学式：
//
//   out = lerp(identity, LUT, s) 查表  ==  lerp(in, LUT(in), s)
//
// 恒等表在三线性插值下是精确复原的（三线性对线性函数无误差），所以这两个写法
// 严格相等 —— 强度不需要再额外做一次混合。
//
// 两条管线的插值方式必须**一样**：CIColorCube 是三线性，而 ffmpeg 的 lut3d
// 默认是 tetrahedral，所以导出侧必须显式写 `interp=trilinear`
//（见 VideoEditExportGraph 的滤镜段）。
//
// 表的排列顺序：**r 变最快，然后 g，然后 b**。CIColorCube 的 `inputCubeData`
// 和 .cube 文件格式恰好是同一个顺序，所以同一份扁平数组两边直接用。

enum FilterLUT {
    /// 立方体边长。33 是业界常用尺寸；实测按强度重算一张 33³ 只要 0.109ms
    /// （拖滑块 60Hz 也只占一帧预算的 1/150），不必退到 17。
    static let dimension = 33

    // MARK: - 表

    /// 满强度的表（RGBA，alpha 恒为 1）。按预设缓存 —— 每次拖强度都重算配方
    /// 是白费，插值只需要这一份和恒等表。
    static func fullTable(for preset: FilterPreset) -> [Float] {
        cache.fullTable(for: preset)
    }

    /// 恒等表 —— 全默认的配方求值出来就是原样返回，所以它和其它表同源，
    /// 不是另写一份。`static let` 的惰性初始化本身是线程安全的。
    static let identityTable: [Float] = makeTable(FilterRecipe())

    /// 按强度插值出来的表。`strength` 夹在 0…1。
    static func table(for preset: FilterPreset, strength: Double) -> [Float] {
        let s = Float(min(max(strength, 0), 1))
        if s >= 1 { return fullTable(for: preset) }
        let identity = identityTable
        if s <= 0 { return identity }
        let full = fullTable(for: preset)
        var out = [Float](repeating: 0, count: full.count)
        for index in full.indices {
            out[index] = identity[index] + (full[index] - identity[index]) * s
        }
        return out
    }

    // MARK: - 预览侧

    /// CIColorCube 的 `inputCubeData`。
    static func cubeData(for preset: FilterPreset, strength: Double) -> Data {
        table(for: preset, strength: strength).withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// 预览用的滤镜对象。
    ///
    /// 用 **`CIColorCubeWithColorSpace`** 而不是 `CIColorCube`：后者在 CI 的工作
    /// 色彩空间（线性）里查表，而 ffmpeg 的 lut3d 查的是**伽马编码后**的 RGB。
    /// 同一份表喂给两边会得到明显不同的画面 —— 指定色彩空间才是同一个定义域。
    ///
    /// `name` 让调用方之后能用 `filters.<name>.inputCubeData` 这条 keypath 只改
    /// 参数、不重建整条链（实测能真的重绘，且比重新赋值 `contentFilters` 便宜）。
    static func previewFilter(
        for preset: FilterPreset, strength: Double, name: String
    ) -> CIFilter? {
        guard let filter = CIFilter(name: "CIColorCubeWithColorSpace") else { return nil }
        filter.setValue(dimension, forKey: "inputCubeDimension")
        filter.setValue(cubeData(for: preset, strength: strength), forKey: "inputCubeData")
        filter.setValue(workingColorSpace, forKey: "inputColorSpace")
        filter.name = name
        return filter
    }

    /// 查表的定义域。视频是 BT.709，取同一条传递函数；系统给不出就退回 sRGB
    /// （两者原色相同，只差传递函数的细节）。
    static let workingColorSpace: CGColorSpace = {
        CGColorSpace(name: CGColorSpace.itur_709)
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
    }()

    // MARK: - 导出侧

    /// .cube 文件正文。和预览那份是**同一张表**，只是换个写法。
    static func cubeFileText(for preset: FilterPreset, strength: Double) -> String {
        let values = table(for: preset, strength: strength)
        var text = "# SrtFlow \(preset.rawValue) @ \(Int((strength * 100).rounded()))%\n"
        text += "LUT_3D_SIZE \(dimension)\n"
        text.reserveCapacity(values.count / 4 * 26 + 64)
        var index = 0
        while index < values.count {
            text += String(
                format: "%.6f %.6f %.6f\n",
                values[index], values[index + 1], values[index + 2]
            )
            index += 4
        }
        return text
    }

    // MARK: - 配方求值

    /// 一格的颜色。输入输出都是 0…1 的伽马编码值。
    static func apply(_ recipe: FilterRecipe, _ rgb: (r: Double, g: Double, b: Double))
        -> (r: Double, g: Double, b: Double) {
        // ① lift / gain：标准调色的两端，lift 抬暗部、gain 缩高光。
        var r = rgb.r * (recipe.gainR - recipe.liftR) + recipe.liftR
        var g = rgb.g * (recipe.gainG - recipe.liftG) + recipe.liftG
        var b = rgb.b * (recipe.gainB - recipe.liftB) + recipe.liftB
        // ② gamma：中间调。
        r = pow(clamp(r), 1 / recipe.gammaR)
        g = pow(clamp(g), 1 / recipe.gammaG)
        b = pow(clamp(b), 1 / recipe.gammaB)
        // ③ 饱和：朝亮度收。亮度权重取 BT.709，和画面本身同一套原色。
        let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
        r = luma + (r - luma) * recipe.saturation
        g = luma + (g - luma) * recipe.saturation
        b = luma + (b - luma) * recipe.saturation
        // ④ 对比：以 0.5 为轴。
        r = (r - 0.5) * recipe.contrast + 0.5
        g = (g - 0.5) * recipe.contrast + 0.5
        b = (b - 0.5) * recipe.contrast + 0.5
        return (clamp(r), clamp(g), clamp(b))
    }

    private static func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }

    static func makeTable(_ recipe: FilterRecipe) -> [Float] {
        let n = dimension
        var table = [Float](repeating: 0, count: n * n * n * 4)
        var index = 0
        let step = 1.0 / Double(n - 1)
        for bi in 0..<n {
            for gi in 0..<n {
                for ri in 0..<n {
                    let out = apply(recipe, (Double(ri) * step, Double(gi) * step, Double(bi) * step))
                    table[index] = Float(out.r)
                    table[index + 1] = Float(out.g)
                    table[index + 2] = Float(out.b)
                    table[index + 3] = 1
                    index += 4
                }
            }
        }
        return table
    }

    // MARK: - 缓存
    //
    // 导出跑在后台线程、预览跑在主线程，所以这份缓存要自己上锁。

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var tables: [FilterPreset: [Float]] = [:]

        func fullTable(for preset: FilterPreset) -> [Float] {
            lock.lock()
            defer { lock.unlock() }
            if let existing = tables[preset] { return existing }
            let table = FilterLUT.makeTable(preset.recipe)
            tables[preset] = table
            return table
        }
    }

    private static let cache = Cache()
}
