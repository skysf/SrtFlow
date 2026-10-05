import Foundation

// MARK: - 缓动曲线
//
// **质感几乎全在这里。**同样是"1 秒内从无到有"，线性和 easeOutCubic 看起来
// 差一个档次，而用户调不出这个差别 —— 所以曲线是内置的，不暴露成参数。
//
// 纯函数、无状态、定义域和值域都夹在 0…1（`back` 和 `spring` 会越界到 1 以上，
// 那正是它们的用途）。预览和导出调的是同一份，不存在"预览的动画更顺"这种事。
// 关键帧的曲线（KeyframeEasing）也只从这里挑，不另写一份。

enum TextEasing {

    /// 线性。只有打字机和擦除用它 —— 那两个的"进度"是离散的字数/宽度，
    /// 再加一层缓动会让节奏忽快忽慢，反而像卡顿。
    static func linear(_ t: Double) -> Double { clamp(t) }

    /// 先快后慢。绝大多数入场/出场的默认曲线：起步果断、收尾从容，
    /// 这就是"高级感"的来源。
    static func easeOutCubic(_ t: Double) -> Double {
        let x = clamp(t)
        return 1 - pow(1 - x, 3)
    }

    /// 先慢后快。出场用它比 easeOut 好：东西该"被抽走"，不是"慢慢停住"。
    static func easeInCubic(_ t: Double) -> Double {
        let x = clamp(t)
        return x * x * x
    }

    /// 带回弹的 easeOut：冲过头一点再退回来。弹性缩放靠它。
    ///
    /// 返回值会**超过 1**（最多约 1.1），调用方不许再夹 —— 夹掉就没有弹性了。
    static func easeOutBack(_ t: Double) -> Double {
        let x = clamp(t)
        let c1 = 1.70158
        let c3 = c1 + 1
        return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2)
    }

    /// 急停（指数的 easeOut）：一出手就几乎到位，余下一点慢慢收住 —— 推近、甩镜头那种「啪」地到位（关键帧的 snap）。
    /// 除以 1 − 2⁻¹⁰：教科书的写法在 t = 1 时差 0.001，到下一帧那一下会跳。
    static func easeOutExpo(_ t: Double) -> Double {
        let x = clamp(t)
        return (1 - pow(2, -10 * x)) / (1 - pow(2, -10))
    }

    /// 弹簧：冲过头约 21%、回摆约 4%，再停住（关键帧的 spring）。阻尼振荡 1 − e^(−6t)·cos(3.5πt)：
    /// 3.5π 让 t = 1 时余弦正好是 0，终点落在 1、不跳。和 `easeOutBack` 一样会超过 1，调用方不许夹。
    static func spring(_ t: Double) -> Double {
        let x = clamp(t)
        guard x < 1 else { return 1 }
        return 1 - exp(-6 * x) * cos(3.5 * .pi * x)
    }

    /// 两头慢中间快（三次）：起步和收尾都从容。关键帧的缓入缓出（KeyframeEasing.easeInOut）用它 ——
    /// 推镜、位移都是「人手」的节奏；比正弦版两头更钝、中间更快。
    static func easeInOutCubic(_ t: Double) -> Double {
        let x = clamp(t)
        return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }

    /// 两头慢中间快，首尾斜率为 0。循环类（呼吸）用它才不会在折返处磕一下。
    static func easeInOutSine(_ t: Double) -> Double {
        let x = clamp(t)
        return -(cos(.pi * x) - 1) / 2
    }

    private static func clamp(_ t: Double) -> Double {
        guard t.isFinite else { return 0 }
        return min(max(t, 0), 1)
    }
}
