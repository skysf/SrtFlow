import Foundation

/// 跑一个外部命令、等它结束，只拿退出码。
///
/// 管什么：起进程、等结束。用结束回调接 continuation，不占着线程等 —— async 函数里 `waitUntilExit()`
/// 会占住 Swift 并发池里的一条线程（docs/architecture/blocking-media-reads.md「同类的别的阻塞」）。
/// 不管什么：命令的输出（全部丢掉，调用方只关心成没成）、超时。起不来（文件不在、没有执行权限）返回 -1。
///
/// 用的人：「连接 AI」调 `claude mcp add`（`AIClientSetup`）、录屏授权的自修复调 `tccutil`
/// （`ScreenCapturePermissionRepair`）。
enum ChildProcess {
    static func exitStatus(_ executable: URL, _ arguments: [String]) async -> Int32 {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: -1)
            }
        }
    }
}
