import CoreGraphics
import Foundation

/// 录屏的坐标与尺寸换算：**纯函数，无 UI、无 ScreenCaptureKit 依赖**，
/// 放在 SrtFlowCore 就是为了能被 `SrtFlowCoreChecks` 覆盖（计划 §6.2 要求
/// 主屏 / 左侧副屏 / 上方副屏 / 不同 scale / 负原点都有纯函数测试）。
///
/// 这里集中处理四件容易各写各的事：
/// 1. AppKit 的全局 **bottom-left** 坐标 ↔ CoreGraphics / ScreenCaptureKit 的
///    全局 **top-left** 坐标；
/// 2. 多屏的**负原点**（本机实测副屏 origin=(-279, -1080)）；
/// 3. **点 → 像素**（Retina）—— 见 `DisplayGeometry` 的说明，这是最容易错的一处；
/// 4. H.264 要求的**偶数**像素宽高，且取整不能把用户选的比例明显破坏。
public enum ScreenRecordingCoordinateMapper {

    /// 一块显示器的几何。
    ///
    /// **`SCDisplay.width/height` 是「点」不是「像素」。**（Phase 0 门槛 10 实测）
    /// `CGDisplayPixelsWide` 名字里带 Pixels，返回的**也是点**，同样不能用。
    /// 只有 `CGDisplayMode.pixelWidth/pixelHeight` 给真实像素。
    /// 照点数配置 `SCStreamConfiguration`，在任何 Retina 机器上都会录成
    /// 半分辨率的糊图 —— 本机 1440×900 点 / 2880×1800 像素。
    public struct DisplayGeometry: Hashable, Sendable {
        /// 全局 top-left 坐标系里的位置与大小，单位**点**（等于 `CGDisplayBounds`）。
        public var boundsInPoints: CGRect
        /// 真实像素尺寸（来自 `CGDisplayMode.pixelWidth/pixelHeight`）。
        public var pixelSize: CGSize

        public init(boundsInPoints: CGRect, pixelSize: CGSize) {
            self.boundsInPoints = boundsInPoints
            self.pixelSize = pixelSize
        }

        /// 点 → 像素的缩放因子。正常是 1 或 2。
        public var pointPixelScale: CGFloat {
            guard boundsInPoints.width > 0 else { return 1 }
            return pixelSize.width / boundsInPoints.width
        }
    }

    // MARK: 坐标系换算

    /// AppKit 全局坐标（bottom-left 原点，Y 向上）→ CG 全局坐标（top-left 原点，Y 向下）。
    ///
    /// **翻转轴是主显示器的高度，不是所有屏幕并集的顶边。**
    /// AppKit 的全局原点是主屏左下角，CG 的全局原点是主屏左上角，两者只差主屏高度；
    /// 副屏无论在上在下都由此自然得到负坐标，不需要并集参与。
    ///
    /// 本机实测对照（这也是当初写错后用来定案的数据）：
    /// ```
    /// 副屏 NSScreen.frame      = (-279,  900, 1920, 1080)   ← AppKit，bottom-left
    /// 副屏 CGDisplayBounds     = (-279, -1080, 1920, 1080)  ← CG，top-left
    /// 主屏高度 900：900 - (900 + 1080) = -1080  ✓
    /// 若误用并集顶边 1980：1980 - (900 + 1080) = 0  ✗ 整整差了一屏
    /// ```
    public static func cgRect(fromAppKit rect: CGRect, mainDisplayHeightInPoints: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX,
            y: mainDisplayHeightInPoints - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// 反向换算（CG top-left → AppKit bottom-left）。翻转轴同样是主屏高度，
    /// 而且公式与正向完全相同 —— 这是对合变换。
    public static func appKitRect(
        fromCG rect: CGRect, mainDisplayHeightInPoints: CGFloat
    ) -> CGRect {
        CGRect(
            x: rect.minX,
            y: mainDisplayHeightInPoints - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// 一步到位：AppKit 全局矩形 → 指定显示器的 display-local top-left 点坐标。
    ///
    /// 这是 `sourceRect` 真正需要的量。**产品代码应优先用它**，而不是自己拼
    /// 「先转 CG 再减 origin」—— 中间那步最容易把翻转轴写错。
    ///
    /// **契约：要求矩形完整落在这块显示器内，否则返回 nil。**
    /// 早先的实现用 `intersection` 把越界部分**静默裁掉**并返回裁剪后的结果，
    /// 与「不落在这块屏上就返回 nil」的文档自相矛盾 —— 更糟的是，用户拖出
    /// 一个部分越界的选区时，录下来的区域会悄悄比他看到的小一圈。
    ///
    /// 夹取是**区域选择 UI 的职责**（它本来就要在拖动中实时 clamp 并显示尺寸），
    /// 不是坐标换算的职责。这里只做换算与归属判定，边界情况一律显式失败。
    public static func displayLocalRect(
        fromAppKit rect: CGRect,
        display: DisplayGeometry,
        mainDisplayHeightInPoints: CGFloat
    ) -> CGRect? {
        let global = cgRect(fromAppKit: rect, mainDisplayHeightInPoints: mainDisplayHeightInPoints)
        // 完整包含才算数：部分跨界、完全在屏外、零面积都返回 nil。
        guard global.width > 0, global.height > 0,
              display.boundsInPoints.contains(global) else { return nil }
        return displayLocalRect(fromGlobalCG: global, display: display)
    }

    /// CG 全局坐标 → 某块显示器的 display-local 点坐标（`SCStreamConfiguration.sourceRect` 用）。
    /// 负原点副屏靠减去 `origin` 自然处理，不需要特判。
    public static func displayLocalRect(
        fromGlobalCG rect: CGRect, display: DisplayGeometry
    ) -> CGRect {
        rect.offsetBy(dx: -display.boundsInPoints.minX, dy: -display.boundsInPoints.minY)
    }

    /// display-local 点坐标 → **AppKit 全局**点坐标（bottom-left 原点）。
    ///
    /// `displayLocalRect(fromAppKit:...)` 的逆运算。录制期间要在被录区域之外盖一层
    /// 遮罩，而摆放 `NSWindow` 用的是 AppKit 坐标系，所以必须能换回去。
    ///
    /// **翻转轴仍是主屏高度**，不是屏幕并集的顶边 —— 这条是复审抓到过的坑，
    /// 而且错误公式同样自反，往返测试测不出来（见 `docs/bugfixes/`
    /// 2026-08-07-screen-recording-foundation-review）。所以自检必须拿本机
    /// 实测的真值对账，不能只验往返。
    public static func appKitRect(
        fromDisplayLocal rect: CGRect,
        display: DisplayGeometry,
        mainDisplayHeightInPoints: CGFloat
    ) -> CGRect {
        // display-local → CG 全局
        let global = rect.offsetBy(
            dx: display.boundsInPoints.minX, dy: display.boundsInPoints.minY
        )
        // CG 全局 → AppKit 全局（绕主屏高度翻转）
        return CGRect(
            x: global.minX,
            y: mainDisplayHeightInPoints - global.maxY,
            width: global.width, height: global.height
        )
    }

    /// display-local 矩形是否完全落在该显示器内。换算结果必须过这一关才能当
    /// `sourceRect` 用 —— 光验往返自反是不够的（错误公式也能自反）。
    public static func isWithinDisplay(_ localRect: CGRect, display: DisplayGeometry) -> Bool {
        let bounds = CGRect(origin: .zero, size: display.boundsInPoints.size)
        return bounds.contains(localRect)
    }

    // MARK: 裁剪与取整

    /// 把区域夹进显示器边界。跨屏区域在产品上不支持，这里保证结果一定落在屏内。
    public static func clamp(_ rect: CGRect, to display: DisplayGeometry) -> CGRect {
        rect.intersection(display.boundsInPoints)
    }

    /// H.264 要求偶数宽高。向下取到偶数，并保证至少 2。
    public static func evenPixels(_ size: CGSize) -> CGSize {
        func even(_ v: CGFloat) -> CGFloat {
            let n = Int(v.rounded(.down))
            return CGFloat(max(2, n - (n % 2)))
        }
        return CGSize(width: even(size.width), height: even(size.height))
    }

    /// 硬件 H.264 编码器的单边上限（Phase 0 门槛 6 实测：M1 上是 4096，
    /// **与总像素无关** —— 5120×1440 像素比 4K 还少也照样掉进软件编码器）。
    public static let hardwareEncoderMaxSide: CGFloat = 4096

    /// 等比缩到两边都 ≤ 上限，再取偶数。不超限就只取偶数。
    public static func fitToHardwareEncoder(
        _ size: CGSize, maxSide: CGFloat = hardwareEncoderMaxSide
    ) -> CGSize {
        let longest = max(size.width, size.height)
        guard longest > maxSide, longest > 0 else { return evenPixels(size) }
        let scale = maxSide / longest
        return evenPixels(CGSize(width: size.width * scale, height: size.height * scale))
    }

    /// 区域（点）→ 最终捕获像素尺寸：先换算到像素，再套硬件编码上限与偶数规则。
    public static func captureSize(
        forRegionInPoints region: CGSize, display: DisplayGeometry
    ) -> CGSize {
        let scale = display.pointPixelScale
        return fitToHardwareEncoder(
            CGSize(width: region.width * scale, height: region.height * scale)
        )
    }

    /// 整块显示器的捕获像素尺寸。
    public static func captureSize(forFullDisplay display: DisplayGeometry) -> CGSize {
        fitToHardwareEncoder(display.pixelSize)
    }

    // MARK: 固定比例

    /// 以 `anchor` 为起点、`current` 为当前指针，按给定比例算最大内接矩形。
    /// `ratio` 为 nil 表示自由模式。
    ///
    /// 支持任意方向拖动：结果始终是标准化矩形（宽高为正）。
    /// 拖拽选区，**保证落在 `bounds` 内且锚点不动**。
    ///
    /// 关键在于「先夹取拖动点，再算矩形」，而不是「先算矩形，再把它平移回屏内」：
    /// 后者在贴边时会让 mouse-down 锚点整体跳走，手感是选区自己滑了一下
    /// （复审三 P2）。夹取 `current` 之后，矩形必然张在两个屏内点之间，
    /// 既不越界、比例也由 `regionRect` 天然保持。
    ///
    /// - Precondition: `anchor` 应当在 `bounds` 内（overlay 覆盖整块屏，
    ///   mouse-down 必然落在屏内）。不在时结果退化为与边界相交。
    /// 区域选择**打开时的默认框**：居中、约占屏幕 60%、比例跟随所选档
    /// （自由档用 16:9 的形状）。
    ///
    /// 真机首测反馈：上来是一片空白、必须自己画一个矩形，用户不知道要干什么。
    /// 给一个默认框，用户改它就行。
    public static func defaultRegion(in bounds: CGRect, ratio: CGFloat?) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        let shape = (ratio ?? (16.0 / 9)) > 0 ? (ratio ?? (16.0 / 9)) : 16.0 / 9
        var width = bounds.width * 0.6
        var height = width / shape
        if height > bounds.height * 0.6 {
            height = bounds.height * 0.6
            width = height * shape
        }
        return CGRect(
            x: (bounds.midX - width / 2).rounded(),
            y: (bounds.midY - height / 2).rounded(),
            width: width.rounded(), height: height.rounded()
        )
    }

    public static func regionRect(
        anchor: CGPoint, current: CGPoint, ratio: CGFloat?, bounds: CGRect
    ) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else {
            return regionRect(anchor: anchor, current: current, ratio: ratio)
        }
        let clampedCurrent = CGPoint(
            x: min(max(current.x, bounds.minX), bounds.maxX),
            y: min(max(current.y, bounds.minY), bounds.maxY)
        )
        let rect = regionRect(anchor: anchor, current: clampedCurrent, ratio: ratio)
        // 锚点在屏内时这一步是恒等的；锚点异常时兜底。
        return bounds.contains(anchor) ? rect : rect.intersection(bounds)
    }

    public static func regionRect(
        anchor: CGPoint, current: CGPoint, ratio: CGFloat?
    ) -> CGRect {
        let dx = current.x - anchor.x
        let dy = current.y - anchor.y
        guard let ratio, ratio > 0 else {
            return CGRect(
                x: min(anchor.x, current.x), y: min(anchor.y, current.y),
                width: abs(dx), height: abs(dy)
            ).standardized
        }
        // 固定比例：取 |dx| 与 |dy| 能容纳的最大内接矩形
        let byWidth = abs(dx)
        let byHeight = abs(dy) * ratio
        let w = min(byWidth, byHeight)
        let h = w / ratio
        return CGRect(
            x: dx >= 0 ? anchor.x : anchor.x - w,
            y: dy >= 0 ? anchor.y : anchor.y - h,
            width: w, height: h
        ).standardized
    }

    /// 取整后比例被破坏得太厉害就该拦下（计划 §6.2：「clamp 后比例不能被偶数
    /// 取整明显破坏」）。返回相对偏差。
    public static func ratioDeviation(_ size: CGSize, expected ratio: CGFloat) -> CGFloat {
        guard size.height > 0, ratio > 0 else { return .infinity }
        return abs((size.width / size.height) - ratio) / ratio
    }

    /// 录制区域的最小可用尺寸（点）。太小的选区没有意义，也会被偶数取整吃掉。
    public static let minimumRegionSide: CGFloat = 64

    public static func isUsableRegion(_ rect: CGRect) -> Bool {
        rect.width >= minimumRegionSide && rect.height >= minimumRegionSide
    }
}
