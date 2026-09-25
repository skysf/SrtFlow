import Foundation

// MARK: - AVAssetReader 的阻塞读取：不进 Swift 并发的协作线程池
//
// `AVAssetReaderOutput.copyNextSampleBuffer()` 会**卡住调用它的线程**，一直等到
// CoreMedia 在自己那边把下一块解出来；而 CoreMedia 那份活沿用调用方的 QoS。
//
// Swift 并发的协作线程池每个 QoS 只有「CPU 核数」条线程，堵住的线程系统不补。
// 同一个 QoS 下同时卡在这一句上的读取一旦凑满核数，这一档就再也派不出线程 ——
// CoreMedia 等的那份活永远排不上，卡着的读取也就永远等不到：**死锁**。从此整档
// QoS 什么都不跑（同档的 GCD 活也一起停），CPU 0%。2026-09-23 实测（8 核）：同时读
// 7 个文件 0.23 秒读完，8 个就再也不返回；打开一份 43 个素材的工程，波形全空，缩略图
// 也是同一档 QoS 上陪着死的
// （docs/bugfixes/2026-09-23-waveform-decode-deadlocks-thread-pool.md）。
//
// 所以：**循环调 `copyNextSampleBuffer()` 的读取一律放到这里的队列上跑**。这里是 GCD
// 的普通线程，堵住了系统会另派线程给 CoreMedia —— 同一个实验挪过来之后，43 个文件在
// 宽度 1 到 64 下全部读完。宽度有上限是为了不和播放抢 CPU、内存，不是为了防死锁。
// 调用方先在 async 里把 `loadTracks` 这类异步加载做完，只把阻塞的那一段交过来。
// 长期约束见 docs/architecture/blocking-media-reads.md。

enum MediaReadQueue {
    /// 波形总览：一个文件从头读到尾。打开工程时几十个文件一起排队；两条并行
    /// （43 个短素材实测 0.77 秒读完，一条一条读 0.92 秒），一条被长录屏占住时
    /// 另一条照样往下走。
    static let overview = make("SrtFlow.MediaRead.overview", qos: .utility, width: 2)
    /// 深度放大时的原始采样块：一块只有一秒、读得快，但用户正盯着看 —— 高一档。
    static let detail = make("SrtFlow.MediaRead.detail", qos: .userInitiated, width: 2)
    /// 导出时把整条混音离线读成文件（ExportAudioMixdown）：一次只导一个，一条就够；
    /// 单独一条队列，长工程读上半分钟也不占波形放大要用的那两条。
    static let export = make("SrtFlow.MediaRead.export", qos: .userInitiated, width: 1)

    /// 在 `queue` 上把一段阻塞的读取跑完，结果交回来（等的这一方只是挂起，不占线程）。
    static func run<T: Sendable>(on queue: OperationQueue, _ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.addOperation { continuation.resume(returning: work()) }
        }
    }

    private static func make(_ name: String, qos: QualityOfService, width: Int) -> OperationQueue {
        let queue = OperationQueue()
        queue.name = name
        queue.qualityOfService = qos
        queue.maxConcurrentOperationCount = width
        return queue
    }
}
