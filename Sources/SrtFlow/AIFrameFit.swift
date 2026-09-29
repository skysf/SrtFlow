import CoreGraphics
import Foundation

// MARK: - 画面怎么放进画布：铺满 / 完整显示 / 按位置和大小（纯值）
//
// 管什么：AI 说「铺满画面、对准这一点」「完整显示」「放到右上角、缩到三分之一」时，算出这一段的
// `crop`（四边各裁多少）和 `placement`（摆放框）；反过来，把一段此刻的裁切和摆放写成 AI 看得懂的
// 几个数（x、y、scale、裁切、盖没盖满画面）。
// 不管什么：黑边、主体在哪（AIBlackBars / AISubjectFocus 算好了当 `active` / `focus` 传进来）、
// 改工程（AIClipEdit 在副本上提交）。
//
// 模型的规矩见 docs/architecture/preview-free-transform.md：裁切按显示方向、每边最多 0.45；摆放是相对
// 画布的归一化中心 + 宽高，nil = 默认布局（裁剩的画面等比完整放进画布、居中）。坐标一律左上原点。
//
// **铺满 = 源画面上一扇和画布同比例的窗，正好映到整幅画布。** 光靠裁切表达不了所有的窗：每边最多
// 裁 0.45，16:9 转 9:16 时窗只有源宽的 0.32，窗贴着左边时右边要裁掉 0.68。所以先用裁切尽量收
// （每边最多 0.45），剩下的交给摆放框 —— 把裁剩的画面放大、挪到窗正好对上画布（摆放框的中心可以在
// 画布外面，框本身照样盖满画布）。裁切一次就收得下时，摆放框正好等于默认布局，存回 nil：用户在检查器里
// 看到的就只是一个裁切。

enum AIFrameFit {
    /// 裁切 + 摆放，一段画面在画布上的样子。两个都是 nil = 默认（不裁、完整放进画布）。
    struct Framing: Equatable {
        var crop: ClipCrop?
        var placement: ClipPlacement?
        /// 铺满：换掉这一段原有的位置 / 大小关键帧（铺满就是要定位置；不换的话关键帧盖过静态摆放，窗就不对了）。
        var replacesMotion = false
        /// 跟拍：摆放框中心在这几个源时刻的位置，写成位置关键帧（AIFollowSubject）；空 = 固定的窗。
        var follow: [AIFollowSubject.Point] = []
    }

    /// 源画面上的整幅（归一化，左上原点）。
    static let wholePicture = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// 裁切之后留下来的那一块（归一化）。
    static func region(of crop: ClipCrop?) -> CGRect {
        guard let crop else { return wholePicture }
        return CGRect(
            x: crop.leading, y: crop.top,
            width: 1 - crop.leading - crop.trailing, height: 1 - crop.top - crop.bottom
        )
    }

    /// 留下 `region` 这一块的裁切（每边最多 0.45，`ClipCrop` 自己夹）。什么都不裁就是 nil。
    static func crop(keeping region: CGRect) -> ClipCrop? {
        let crop = ClipCrop(
            top: region.minY, bottom: 1 - region.maxY, leading: region.minX, trailing: 1 - region.maxX
        )
        return crop.isEmpty ? nil : crop
    }

    // MARK: 三种放法

    /// 完整显示 `active`（去掉黑边 / 手动裁切剩下的那块）：裁切就是它，摆放回默认。
    static func fit(active: CGRect) -> Framing {
        Framing(crop: crop(keeping: active), placement: nil)
    }

    /// 铺满画布：在 `active` 里取和画布同比例、尽量大的一扇窗，中心尽量对准 `focus`（源画面上的一点，
    /// 归一化）。拿不到画面尺寸（纯音频、没探测到）返回 nil。
    static func fill(_ clip: EditClip, canvas: CGSize, active: CGRect, focus: CGPoint) -> Framing? {
        guard let display = clip.info?.displaySize, display.width > 0, display.height > 0,
              canvas.width > 0, canvas.height > 0, active.width > 0, active.height > 0 else { return nil }
        let window = fillWindow(display: display, canvas: canvas, active: active, focus: focus)
        let crop = crop(keeping: window)
        let kept = region(of: crop)
        // 窗映到整幅画布：源画面上一个归一化单位在画布上是多少像素（横竖同一个像素比例，窗和画布同比例）。
        let perUnitX = canvas.width / window.width
        let perUnitY = canvas.height / window.height
        let frame = CGRect(
            x: (kept.minX - window.minX) * perUnitX, y: (kept.minY - window.minY) * perUnitY,
            width: kept.width * perUnitX, height: kept.height * perUnitY
        )
        var cropped = clip
        cropped.crop = crop
        let placement = PlacementDefault.normalized(
            ClipPlacement(frame: frame, in: canvas), fallback: cropped.defaultPlacement(canvas: canvas), canvas: canvas
        )
        return Framing(crop: crop, placement: placement, replacesMotion: true)
    }

    /// 铺满用的那扇窗（归一化）：和画布同比例、在 `active` 里尽量大，中心尽量对准 `focus`，出不了 `active`。
    static func fillWindow(display: CGSize, canvas: CGSize, active: CGRect, focus: CGPoint) -> CGRect {
        let canvasAspect = canvas.width / canvas.height
        let activeAspect = (active.width * display.width) / (active.height * display.height)
        var width = active.width
        var height = active.height
        if activeAspect > canvasAspect {
            width = active.height * display.height * canvasAspect / display.width
        } else {
            height = active.width * display.width / canvasAspect / display.height
        }
        let x = min(max(focus.x - width / 2, active.minX), active.maxX - width)
        let y = min(max(focus.y - height / 2, active.minY), active.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// 画面中心在画布上能放到哪（AI 的 x / y、位置关键帧）：画面比画布大时，中心要出到 0–1 外边，画面的边才够得到画布的边
    /// （横屏素材铺满竖屏是 3.16 倍，0–1 只看得到中间那六成多）。scale 最大 6、1 = 放得下，所以 −2…3 够到任何一边
    /// （2026-09-29 验收实剪：放大的幻灯片只看得到中间）。工具说明里的范围和它对账（check-mcp.sh）。
    static let centerRange = -2.0...3.0

    /// 按位置和大小摆：`x` / `y` 是画面中心在画布上的位置（0…1 在画布里，见 `centerRange`），`scale` 相对默认布局
    /// （1 = 裁剩的画面完整放进画布）。不给的沿用这一段此刻的样子。
    static func place(
        _ clip: EditClip, canvas: CGSize, crop: ClipCrop?, x: Double?, y: Double?, scale: Double?
    ) -> Framing {
        let now = describe(clip, canvas: canvas)
        var cropped = clip
        cropped.crop = crop
        let base = cropped.defaultPlacement(canvas: canvas)
        let factor = min(max(scale ?? now.scale, 0.02), 8)
        func inRange(_ value: Double) -> Double { min(max(value, centerRange.lowerBound), centerRange.upperBound) }
        let placement = ClipPlacement(
            centerX: inRange(x ?? now.x), centerY: inRange(y ?? now.y), width: base.width * factor, height: base.height * factor
        )
        return Framing(crop: crop, placement: PlacementDefault.normalized(placement, fallback: base, canvas: canvas))
    }

    // MARK: 写给 AI 看

    /// 这一段此刻怎么放在画布上。
    struct Summary: Equatable {
        /// 画面中心在画布上的位置（0…1）。
        var x: Double
        var y: Double
        /// 相对默认布局的大小（1 = 裁剩的画面完整放进画布）。宽高拉得不一样时是宽的那个。
        var scale: Double
        /// 宽高被拉成了不同的比例（用户拖过边上的把手）。
        var stretched: Bool
        var crop: ClipCrop?
        /// 画面盖满整个画布（四边都没露出下面那一层）。旋转不算在里面。
        var fillsFrame: Bool
        /// 用的是默认布局、没有裁切。
        var isDefault: Bool
    }

    static func describe(_ clip: EditClip, canvas: CGSize) -> Summary {
        let base = clip.defaultPlacement(canvas: canvas)
        let current = clip.resolvedPlacement(canvas: canvas)
        let scaleX = base.width > 0 ? current.width / base.width : 1
        let scaleY = base.height > 0 ? current.height / base.height : 1
        let frame = current.frame(in: canvas)
        let fills = frame.minX <= 0.5 && frame.minY <= 0.5
            && frame.maxX >= canvas.width - 0.5 && frame.maxY >= canvas.height - 0.5
        return Summary(
            x: current.centerX, y: current.centerY, scale: scaleX,
            stretched: abs(scaleX - scaleY) > 0.01 * max(abs(scaleX), abs(scaleY), 0.0001),
            crop: clip.crop.flatMap { $0.isEmpty ? nil : $0 },
            fillsFrame: fills,
            isDefault: clip.placement == nil && (clip.crop?.isEmpty ?? true)
        )
    }
}
