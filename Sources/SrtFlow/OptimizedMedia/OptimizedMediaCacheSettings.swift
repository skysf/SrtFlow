import Combine
import Foundation

// MARK: - 设置里「优化媒体」那一节的状态：缓存占了多少、上限、清空
//
// 管什么：设置窗口里显示的占用（`OptimizedMediaStore.totalBytes()`，在 proxy 队列上算、和转码串着）、上限的几档（读写只经
// Store，改完当场 `enforceCapacity` 丢掉超出的）、「清空」（proxy 队列上 `removeAll`，然后让当前工程的协调者作废内存里的表、
// 重排预览）。**只有设置里那一节订阅它**（ObservableObject），不挂在工程上（docs/architecture/preview-perf-ratchet.md 第十节）。
// 不管什么：缓存目录怎么存（OptimizedMediaStore）、转码队列（OptimizedMediaCoordinator）、界面（OptimizedMediaSettingsSection）。
//
// 为什么清空之后要 `reset()` + `scheduleRebuild()`：协调者内存里那张「转好的块」表还指着删掉的文件 —— builder 插不进去会
// 退回原片（不黑），但表上写着「齐了」，`sync` 就不会再把这些块排进转码队列，优化媒体从此不回来。作废表、重建一次，
// 重建落地的 `sync` 重新按这份时间线排队，后台重转。先 `reset()` 一次是为了取消路上的那一块（不然 `removeAll` 在 proxy 队列上
// 要排在它后面、转好的还会落进刚清空的目录）。

@MainActor
final class OptimizedMediaCacheSettings: ObservableObject {
    static let shared = OptimizedMediaCacheSettings()

    /// 缓存占了多少字节；还没算出来是 nil。
    @Published private(set) var usedBytes: Int64?
    /// 上限（和记住的那份一致；只经 Store 读写）。
    @Published private(set) var capacityBytes: Int64
    /// 清空之后在按钮旁说的一句（不弹模态框）。
    @Published private(set) var message: String?
    @Published private(set) var isClearing = false

    private init() {
        capacityBytes = OptimizedMediaStore.capacityBytes
    }

    /// 重新算占用（设置那一节出现时、之后每隔几秒、清空 / 改上限之后）。
    func refresh() async {
        let bytes = await MediaReadQueue.run(on: MediaReadQueue.proxy) { OptimizedMediaStore.totalBytes() }
        if usedBytes != bytes { usedBytes = bytes }
    }

    /// 设置里选了一档：记住，立刻把超出的块丢掉（最久没用的先）。
    func setCapacity(_ bytes: Int64) {
        OptimizedMediaStore.setCapacityBytes(bytes)
        let limit = OptimizedMediaStore.capacityBytes
        capacityBytes = limit
        Task { [weak self] in
            await MediaReadQueue.run(on: MediaReadQueue.proxy) { OptimizedMediaStore.enforceCapacity(limit: limit) }
            await self?.refresh()
        }
    }

    /// 「清空」：删掉整个缓存目录，当前工程的协调者作废、预览重建一次（用原片，后台重转）。
    func clear() {
        guard !isClearing else { return }
        isClearing = true
        let project = VideoEditProject.shared
        project.optimizedMedia.reset()  // 取消路上的那一块，别让它落进刚清空的目录
        Task { [weak self] in
            await MediaReadQueue.run(on: MediaReadQueue.proxy) { OptimizedMediaStore.removeAll() }
            // 清空之后：作废内存里那张表、重建一次 —— 不然合成还指着删掉的块文件，builder 退回原片但不会再排转码。
            project.optimizedMedia.reset()
            project.scheduleRebuild()
            guard let self else { return }
            self.isClearing = false
            self.message = L10n("Cleared. The preview uses the original files and prepares optimized media again in the background.")
            await self.refresh()
        }
    }
}
