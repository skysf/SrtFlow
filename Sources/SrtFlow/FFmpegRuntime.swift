import AppKit
import Foundation

/// 找到并检验要用的 ffmpeg。
///
/// 优先用随 App 一起分发的那份：它是原生 arm64 且带 libass。系统里的
/// `/usr/local/bin/ffmpeg` 经常是 x86_64 版（Intel 版 Homebrew 的默认前缀），
/// 在 M 系列上走 Rosetta 转译，跑 `-preset slow` 要慢一倍以上；而且默认构建
/// 未必带 libass，没有 libass 就没有 `subtitles` 滤镜，字幕根本烧不进去。
struct FFmpegRuntime: Sendable {

    enum Source: Equatable, Sendable {
        /// 随 App 分发的（Contents/Helpers/ffmpeg）。
        case bundled
        /// 开发时从仓库的 vendor/ 目录找到的。
        case vendor
        /// SRTFLOW_FFMPEG 环境变量指定的。
        case environmentOverride
        /// 系统里装的。
        case system
    }

    let url: URL
    let source: Source
    let architecture: String
    let hasLibass: Bool
    let versionLine: String

    /// 原生 arm64，没有 Rosetta 转译开销。
    var isNativeAppleSilicon: Bool { architecture == "arm64" }
    /// 能不能烧制字幕。
    var canBurnInSubtitles: Bool { hasLibass }

    var sourceDescription: String {
        switch source {
        case .bundled: return L10n("Bundled with SrtFlow")
        case .vendor: return L10n("Repository vendor/ directory")
        case .environmentOverride: return L10n("SRTFLOW_FFMPEG override")
        case .system: return url.path
        }
    }

    // MARK: - 定位

    /// 定位结果。「找不到」和「找到了但被系统拦下」要分开报，因为后者的解决办法
    /// 完全不同，而且用户光看错误信息根本猜不到。
    enum Lookup {
        case found(FFmpegRuntime)
        /// 包内的 ffmpeg 存在，但带着下载隔离标记、执行即被杀。
        case blockedByQuarantine(bundlePath: String)
        case missing
    }

    static func locate() -> Lookup {
        // 从别人机器上第一次打开时，整个 App 包可能带着下载隔离标记，那样包内的
        // ffmpeg 会被系统直接杀掉。先尽力修一下（能不能修成看包是否可写）。
        Quarantine.repairOwnBundleIfNeeded()

        for (candidate, source) in candidates() {
            guard FileManager.default.isExecutableFile(atPath: candidate.path) else { continue }
            guard let probed = probe(url: candidate, source: source) else { continue }
            return .found(probed)
        }

        // 一个都没探测成功。如果随包那份明明在、却带着隔离标记，那就是被拦下了，
        // 而不是没装 —— 这时候要给的是「怎么解隔离」而不是「怎么安装」。
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ffmpeg")
        if FileManager.default.fileExists(atPath: bundled.path),
           Quarantine.isFlagged(atPath: bundled.path) || Quarantine.isFlagged(atPath: Bundle.main.bundleURL.path) {
            return .blockedByQuarantine(bundlePath: Bundle.main.bundleURL.path)
        }
        return .missing
    }

    private static func candidates() -> [(URL, Source)] {
        var result: [(URL, Source)] = []

        if let override = ProcessInfo.processInfo.environment["SRTFLOW_FFMPEG"], !override.isEmpty {
            result.append((URL(fileURLWithPath: override), .environmentOverride))
        }

        // 打好包的 .app：Contents/Helpers/ffmpeg
        result.append((
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ffmpeg"),
            .bundled
        ))

        // 开发时（swift run）：从可执行文件往上找仓库里的 vendor/ffmpeg
        var directory = Bundle.main.bundleURL
        for _ in 0..<6 {
            result.append((directory.appendingPathComponent("vendor/ffmpeg"), .vendor))
            directory = directory.deletingLastPathComponent()
        }

        // 系统安装的兜底。/opt/homebrew 排在前面：Apple Silicon 版 Homebrew
        // 装在那儿，装出来的是原生 arm64。
        for path in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"] {
            result.append((URL(fileURLWithPath: path), .system))
        }

        return result
    }

    private static func probe(url: URL, source: Source) -> FFmpegRuntime? {
        guard let version = runCapturingOutput(url: url, arguments: ["-hide_banner", "-version"]),
              let versionLine = version.split(separator: "\n").first.map(String.init),
              versionLine.contains("ffmpeg version") else { return nil }

        // 必须按实际滤镜列表判断，不能只看 configuration 里的 --enable-libass：
        // 某些构建的 configuration 行并不完整。
        let filters = runCapturingOutput(url: url, arguments: ["-hide_banner", "-filters"]) ?? ""
        let hasLibass = filters.contains(" subtitles ")

        return FFmpegRuntime(
            url: url,
            source: source,
            architecture: machOArchitecture(of: url) ?? "unknown",
            hasLibass: hasLibass,
            versionLine: versionLine
        )
    }

    private static func runCapturingOutput(url: URL, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = url
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    // MARK: - 读 Mach-O 头判断架构

    /// 直接读文件头，比起调 `lipo` 少一次进程启动。
    ///
    /// 判断字节序时容易绕晕，这里统一按「文件里的字节顺序」拼成一个数再比：
    /// 一个普通的 arm64 macOS 二进制，开头四字节是 `cf fa ed fe`，拼出来就是
    /// 0xCFFAEDFE —— 也就是小端存放的 MH_MAGIC_64(0xFEEDFACF)。
    static func machOArchitecture(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 8), header.count == 8 else { return nil }

        /// 按文件里的字节先后顺序拼成 UInt32。
        func rawUInt32(at offset: Int) -> UInt32 {
            let start = header.startIndex + offset
            return header[start..<start + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }

        let magic = rawUInt32(at: 0)
        let rawCPUType = rawUInt32(at: 4)

        switch magic {
        case 0xCFFA_EDFE, 0xCEFA_EDFE:
            // 小端文件（现代 macOS 上都是这种），cputype 也要按小端读。
            return name(forCPUType: Int32(bitPattern: rawCPUType.byteSwapped))
        case 0xFEED_FACF, 0xFEED_FACE:
            // 大端文件，早年的 PowerPC 才有。
            return name(forCPUType: Int32(bitPattern: rawCPUType))
        case 0xCAFE_BABE, 0xCAFE_BABF:
            // 通用二进制：架构表跟在头后面，且规定按大端存放。
            return fatArchitectures(handle: handle, count: rawCPUType)
        default:
            return nil
        }
    }

    /// - Parameter count: fat 头里的 nfat_arch。
    private static func fatArchitectures(handle: FileHandle, count: UInt32) -> String? {
        guard count > 0, count < 32 else { return nil }

        var names: [String] = []
        for index in 0..<Int(count) {
            // fat_arch 每条 20 字节，cputype 在最前面，大端存放。
            try? handle.seek(toOffset: UInt64(8 + index * 20))
            guard let entry = try? handle.read(upToCount: 4), entry.count == 4 else { continue }
            let cpuType = entry.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            if let name = name(forCPUType: Int32(bitPattern: cpuType)) {
                names.append(name)
            }
        }
        // 通用二进制里只要有 arm64，在 M 系列上跑的就是原生那一片。
        if names.contains("arm64") { return "arm64" }
        return names.first
    }

    private static func name(forCPUType cpuType: Int32) -> String? {
        switch cpuType {
        case 0x0100_000C: return "arm64"
        case 0x0000_000C: return "arm"
        case 0x0100_0007: return "x86_64"
        case 0x0000_0007: return "i386"
        default: return nil
        }
    }
}

/// 把定位结果发布给界面，并在启动时异步解析，避免卡住第一帧。
@MainActor
final class MediaToolchain: ObservableObject {
    @Published private(set) var runtime: FFmpegRuntime?
    @Published private(set) var isResolving = true
    /// 被下载隔离标记拦下时记下 App 包路径，好在提示里给出确切的修复命令。
    @Published private(set) var quarantinedBundlePath: String?

    static let shared = MediaToolchain()

    private init() {}

    func resolveIfNeeded() {
        guard isResolving, runtime == nil else { return }
        Task {
            // 探测要起两个子进程，挪到后台线程去做。
            let lookup = await Task.detached(priority: .userInitiated) {
                FFmpegRuntime.locate()
            }.value
            switch lookup {
            case .found(let located):
                self.runtime = located
            case .blockedByQuarantine(let path):
                self.quarantinedBundlePath = path
            case .missing:
                break
            }
            self.isResolving = false
        }
    }

    /// 解隔离的命令，可以直接复制到终端执行。给「仍要打开」之后仍然被拦时兜底。
    var quarantineFixCommand: String? {
        guard let quarantinedBundlePath else { return nil }
        return "xattr -dr com.apple.quarantine \"\(quarantinedBundlePath)\""
    }

    /// 直接跳到「系统设置 → 隐私与安全性」。这是不碰终端就能放行的那条路。
    func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?General") else { return }
        NSWorkspace.shared.open(url)
    }

    /// 缺 ffmpeg，或者有但不能烧字幕时，给界面用的说明文字。
    var warning: String? {
        guard !isResolving else { return nil }

        // 这一条必须排在「找不到」前面：文件明明就在包里，是被系统拦下的。
        // 这时候提示去 brew install 只会让人白折腾。
        //
        // 先给不用碰终端的那条路（系统设置里点「仍要打开」），命令只作为兜底 ——
        // 放行之后 App 会自己清掉包上的隔离标记，通常一次就好了。
        if let command = quarantineFixCommand {
            return String(
                format: L10n("macOS blocked this app because it was downloaded from the internet. Open System Settings → Privacy & Security, click “Open Anyway” for SrtFlow, then open SrtFlow again. If compression still fails immediately, paste this line into Terminal instead:\n%@"),
                command
            )
        }

        guard let runtime else {
            return L10n("ffmpeg was not found. Rebuild the app with scripts/build-app.sh, or install it with: brew install ffmpeg")
        }
        if !runtime.canBurnInSubtitles {
            return L10n("This ffmpeg build has no libass, so subtitles cannot be burned in. Compression still works.")
        }
        if !runtime.isNativeAppleSilicon {
            return L10n("This ffmpeg is not a native arm64 build, so it runs under Rosetta translation and encodes roughly twice as slowly.")
        }
        return nil
    }
}
