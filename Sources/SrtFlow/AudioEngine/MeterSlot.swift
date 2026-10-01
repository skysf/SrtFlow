import Foundation
import Synchronization

// MARK: - 电平表的无锁槽：渲染块按拍写峰值，界面按需取走
//
// 管什么：一条表（某条轨、或总表）自上次界面取走以来的峰值（左右两路，线性）。渲染线程只做原子的
// 「比大就换」，界面每拍 `take()` 取走并清零 —— 没有锁、没有环、没有按位置扫描。
// 不管什么：回落 / 峰值保持 / 红灯的平滑（AudioMeterEngine.reading 照旧做），tap 那条路的环（它还是老样子）。
//
// 为什么要它（docs/architecture/audio-engine.md）：引擎那条路以前把每一拍的采样写进 tap 用的环（渲染线程拿锁、
// 逐采样 add），界面每秒 300 次扫 50 ms 的窗（主线程拿同一把锁）——debug 构建的冒烟里主线程因此卡 60–130 ms。
// 电平表要的只是「这一拍多响」，一个数就够。

final class MeterSlot: @unchecked Sendable {
    private let left = Atomic<Float>(0)
    private let right = Atomic<Float>(0)

    /// 渲染线程：这一拍的峰值，比槽里的大就换上（比较交换，不加锁）。
    func offer(left newLeft: Float, right newRight: Float) {
        Self.raise(left, to: newLeft)
        Self.raise(right, to: newRight)
    }

    /// 渲染线程：扫一遍这一拍的两路采样，记峰值。
    func offer(frames: Int, left samplesLeft: UnsafePointer<Float>, right samplesRight: UnsafePointer<Float>, scale: Float = 1) {
        var peakLeft: Float = 0
        var peakRight: Float = 0
        for index in 0..<frames {
            peakLeft = max(peakLeft, abs(samplesLeft[index]))
            peakRight = max(peakRight, abs(samplesRight[index]))
        }
        offer(left: peakLeft * scale, right: peakRight * scale)
    }

    /// 界面：取走自上次以来的峰值并清零。
    func take() -> (left: Float, right: Float) {
        (left.exchange(0, ordering: .acquiringAndReleasing), right.exchange(0, ordering: .acquiringAndReleasing))
    }

    /// 自检：看一眼不清零。
    func peek() -> (left: Float, right: Float) {
        (left.load(ordering: .acquiring), right.load(ordering: .acquiring))
    }

    /// 原子的「比大就换」：别的线程同时写了更大的值就放弃。`Atomic` 不可拷贝，按借用传。
    private static func raise(_ slot: borrowing Atomic<Float>, to value: Float) {
        var current = slot.load(ordering: AtomicLoadOrdering.relaxed)
        while value > current {
            let (exchanged, original) = slot.weakCompareExchange(
                expected: current, desired: value, ordering: AtomicUpdateOrdering.relaxed
            )
            if exchanged { return }
            current = original
        }
    }
}
