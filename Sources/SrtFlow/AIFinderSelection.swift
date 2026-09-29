import Foundation

// MARK: - 访达里选中了什么（给 AI 的 open_folder from_finder 用）
//
// 管什么：方案第 22 条「素材从哪来：访达选中」。问访达此刻选中了哪些文件 / 文件夹；什么都没选就用最前面那个访达窗口
// 正开着的文件夹。用系统自带的 `osascript`（AppleScript），第一次会弹「SrtFlow 想要控制访达」，要用户点好；
// 用途说明在 Info.plist 的 NSAppleEventsUsageDescription（中英文在 InfoPlist.strings）。
// 不管什么：拿到之后列文件、登记文件夹（AIProjectTools.openFolder）。
//
// 等用户点授权框的时候 osascript 一直不返回：它是子进程，等它的那条线程在 `MediaReadQueue.analysis` 上，不卡界面、
// 不进 Swift 并发的线程池；最多等 `timeout` 秒，到点就停掉它、请 AI 让用户点完再来一次。

enum AIFinderSelection {
    struct Failure: Error, Sendable {
        let message: String
    }

    static let timeout = 50.0

    /// 选中的每一项一行 POSIX 路径；什么都没选就是最前面那个访达窗口的文件夹；连窗口都没有就是空。
    static let script = """
    tell application "Finder"
        set out to ""
        repeat with anItem in (selection as alias list)
            set out to out & POSIX path of anItem & linefeed
        end repeat
        if out is "" then
            try
                set out to POSIX path of (target of front Finder window as alias)
            end try
        end if
        return out
    end tell
    """

    static func read() async throws -> [URL] {
        let outcome = await MediaReadQueue.run(on: MediaReadQueue.analysis) { runScript() }
        switch outcome {
        case .success(let text):
            let urls = paths(from: text)
            guard !urls.isEmpty else {
                throw Failure(message: "Nothing is selected in Finder and no Finder window is open. Ask the user to select the files or open the folder in Finder, or to tell you the folder.")
            }
            return urls
        case .failure(let failure):
            throw failure
        }
    }

    /// 选中的东西 → 登记哪个文件夹、只列哪些：只选了一个文件夹就是它本身、全列；选了文件（或文件加文件夹）就是它们
    /// 共同的上级文件夹、只列选中的。纯值，自检够得着。
    static func workspace(for items: [URL], isDirectory: (URL) -> Bool) -> (folder: URL, only: [URL]?) {
        if items.count == 1, let single = items.first, isDirectory(single) { return (single, nil) }
        let parents = items.map { $0.deletingLastPathComponent().standardizedFileURL.pathComponents }
        var common = parents.first ?? ["/"]
        for components in parents.dropFirst() {
            common = Array(zip(common, components).prefix { $0 == $1 }.map(\.0))
        }
        let path = common.count <= 1 ? "/" : "/" + common.dropFirst().joined(separator: "/")
        return (URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL, items)
    }

    /// `url` 是不是选中的东西之一，或者在选中的某个文件夹里面。
    static func isSelected(_ url: URL, among items: [URL]) -> Bool {
        let path = url.standardizedFileURL.path
        return items.contains { path == $0.standardizedFileURL.path || path.hasPrefix($0.standardizedFileURL.path + "/") }
    }

    /// osascript 的输出 → 路径（一行一个，空行不要）。
    static func paths(from output: String) -> [URL] {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
    }

    /// osascript 失败时说给 AI 听的话。-1743：用户没允许 SrtFlow 控制访达。
    static func explain(status: Int32, error: String) -> String {
        if error.contains("-1743") || error.lowercased().contains("not authorized") || error.lowercased().contains("not allowed") {
            return "The user has not allowed SrtFlow to see Finder's selection. They can allow it in System Settings > Privacy & Security > Automation > SrtFlow > Finder, or tell you the folder instead."
        }
        return "SrtFlow could not read Finder's selection (osascript exited with \(status): \(error.trimmingCharacters(in: .whitespacesAndNewlines)))."
    }

    /// 同步跑完 osascript。**只在 `MediaReadQueue.analysis` 上调**：第一次要等用户点授权框。
    private static func runScript() -> Result<String, Failure> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return .failure(Failure(message: "SrtFlow could not run osascript: \(error.localizedDescription)"))
        }
        // 边跑边把输出读走：选中上千个文件时路径能超过管道的 64KB，不读的话 osascript 卡在写上、永远不退出。
        let drained = DispatchGroup()
        nonisolated(unsafe) var outputData = Data()
        nonisolated(unsafe) var errorData = Data()
        DispatchQueue.global(qos: .userInitiated).async(group: drained) {
            outputData = output.fileHandleForReading.readDataToEndOfFile()
        }
        DispatchQueue.global(qos: .userInitiated).async(group: drained) {
            errorData = errors.fileHandleForReading.readDataToEndOfFile()
        }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return .failure(Failure(message: "macOS is asking the user whether SrtFlow may control Finder. Ask them to click OK in that dialog, then call open_folder with from_finder again."))
        }
        drained.wait()
        let text = String(data: outputData, encoding: .utf8) ?? ""
        let error = String(data: errorData, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            return .failure(Failure(message: explain(status: process.terminationStatus, error: error)))
        }
        return .success(text)
    }
}
