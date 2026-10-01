import Foundation
import Synchronization

// MARK: - 给渲染块看的「此刻生效的那一份」：主线程 / 喂样线程发布，渲染块无锁地取
//
// 管什么：一个引用的原子交换。发布方把新值存进去，渲染块每拍取一次。渲染块里不许加锁、不许分配，
// 所以不能用锁保护的变量；用 `Atomic<UnsafeMutableRawPointer?>` 放一个不带引用计数的指针。
// 不管什么：值本身的含义。
//
// 生命周期：发布方自己留着**最近 8 份**不放（`retained`），所以渲染块取到的那一份至少在接下来 8 次发布
// 之内都活着 —— 一拍渲染不到 10 ms，发布最快也是按用户操作来的，远到不了 8 次。渲染块取到的是 +0 的引用，
// 绑到局部变量时 Swift 会 retain / release 一次（原子加减，不分配）。

final class AudioPublished<Value: AnyObject>: @unchecked Sendable {
    private let pointer = Atomic<UnsafeMutableRawPointer?>(nil)
    private var retained: [Value] = []
    private let lock = NSLock()

    init(_ initial: Value? = nil) {
        if let initial { publish(initial) }
    }

    /// 发布方调（任何非渲染线程；多个发布方之间用锁串行）。
    func publish(_ value: Value) {
        lock.lock()
        retained.append(value)
        if retained.count > 8 { retained.removeFirst(retained.count - 8) }
        lock.unlock()
        pointer.store(Unmanaged.passUnretained(value).toOpaque(), ordering: .releasing)
    }

    /// 渲染块调：此刻生效的那一份（还没发布过就是 nil）。
    func load() -> Value? {
        guard let raw = pointer.load(ordering: .acquiring) else { return nil }
        return Unmanaged<Value>.fromOpaque(raw).takeUnretainedValue()
    }
}
