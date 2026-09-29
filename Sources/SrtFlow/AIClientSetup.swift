import AppKit
import Foundation
import SrtFlowMCPKit

// MARK: - 「连接 AI」：把 SrtFlow 写进 Claude / Codex 的配置
//
// 管什么：三个客户端各自的配置在哪、现在连没连、点「连接」「断开」时怎么改、
// 「复制一段话」里写什么。产品口径见 docs/plans/2026-09-27-mcp.md 第 2、5 条。
// 不管什么：配置文件里那一项怎么增删（AIClientConfigFiles，纯值）、界面（AIConnectSettingsView）。
//
// 三家三种办法，各有理由：
// - **Claude 桌面版**：官方就是让用户改 claude_desktop_config.json，直接改（先备份一份）。
// - **Claude Code**：配置在 ~/.claude.json，正在跑的 Claude Code 会随时整份重写它，直接改会被冲掉。
//   所以走它自己的命令行 `claude mcp add`；找不到命令行就让用户「复制一段话」贴给它自己装。
// - **Codex**：~/.codex/config.toml，桌面版和命令行共用一份，很少被程序重写，直接改（先备份）。
//
// 连上的同时放行 SrtFlow 的工具（方案第 35 条：少问，只有删文件由 SrtFlow 自己在对话里问）：Claude Code 往
// ~/.claude/settings.json 的 permissions.allow 里加 `mcp__srtflow`（先备份），Codex 在那张表里写不问就放行。
// Claude 桌面版的「总是允许」只能在它自己的界面里点，连上之后的提示里告诉用户在哪点。

@MainActor
final class AIClientSetup: ObservableObject {
    static let shared = AIClientSetup()

    enum Client: String, CaseIterable, Identifiable {
        case claudeDesktop, claudeCode, codex

        var id: String { rawValue }

        var title: String {
            switch self {
            case .claudeDesktop: return "Claude Desktop"
            case .claudeCode: return "Claude Code"
            case .codex: return "Codex"
            }
        }
    }

    enum Status: Equatable {
        case notInstalled
        case notConnected
        case connected
        /// 连着这一份，但工具还没放行（以前连的、或者用户自己删了那条规则）：每个工具都会问。再点一次「连接」补上。
        case connectedAsking
        /// 连着的是另一份 SrtFlow（App 挪过位置、或者装过测试版）。
        case connectedElsewhere
    }

    @Published private(set) var statuses: [Client: Status] = [:]
    @Published private(set) var busy: Client?
    @Published var message: String?

    private let home = MCPBridge.realHomeDirectory()

    private init() {}

    /// 包里的那个小程序。`swift run` 直接跑的开发版里没有它。
    var helperURL: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/srtflow-mcp")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    // MARK: 现在连没连

    func refresh() {
        for client in Client.allCases { statuses[client] = status(of: client) }
    }

    private func status(of client: Client) -> Status {
        guard isInstalled(client) else { return .notInstalled }
        let command: String?
        switch client {
        case .claudeDesktop: command = AIClientConfigFiles.jsonCommand(in: FileManager.default.contents(atPath: claudeDesktopConfig))
        case .claudeCode: command = AIClientConfigFiles.jsonCommand(in: FileManager.default.contents(atPath: home + "/.claude.json"))
        case .codex: command = (try? String(contentsOfFile: codexConfig, encoding: .utf8)).flatMap(AIClientConfigFiles.tomlCommand(in:))
        }
        guard let command else { return .notConnected }
        guard command == helperURL?.path else { return .connectedElsewhere }
        switch client {
        case .claudeDesktop:
            return .connected
        case .claudeCode:
            let settings = FileManager.default.contents(atPath: claudeCodeSettings)
            return AIClientConfigFiles.jsonAllows(rule: AIClientConfigFiles.claudeCodeAllowRule, in: settings) ? .connected : .connectedAsking
        case .codex:
            let text = (try? String(contentsOfFile: codexConfig, encoding: .utf8)) ?? ""
            return AIClientConfigFiles.tomlApproves(in: text) ? .connected : .connectedAsking
        }
    }

    private func isInstalled(_ client: Client) -> Bool {
        let fm = FileManager.default
        switch client {
        case .claudeDesktop:
            return fm.fileExists(atPath: "/Applications/Claude.app") || fm.fileExists(atPath: (claudeDesktopConfig as NSString).deletingLastPathComponent)
        case .claudeCode:
            return fm.fileExists(atPath: home + "/.claude.json") || claudeCLI != nil
        case .codex:
            return fm.fileExists(atPath: "/Applications/Codex.app") || fm.fileExists(atPath: home + "/.codex")
        }
    }

    private var claudeDesktopConfig: String { home + "/Library/Application Support/Claude/claude_desktop_config.json" }
    private var claudeCodeSettings: String { home + "/.claude/settings.json" }
    private var codexConfig: String { home + "/.codex/config.toml" }

    // MARK: 连接 / 断开

    func connect(_ client: Client) async {
        guard let helper = helperURL else { return }
        await change(client, connecting: true, helper: helper.path)
    }

    func disconnect(_ client: Client) async {
        await change(client, connecting: false, helper: helperURL?.path ?? "")
    }

    private func change(_ client: Client, connecting: Bool, helper: String) async {
        busy = client
        defer {
            busy = nil
            refresh()
        }
        do {
            switch client {
            case .claudeDesktop:
                try rewrite(claudeDesktopConfig) { data in
                    connecting ? try AIClientConfigFiles.jsonAdding(command: helper, to: data)
                        : try AIClientConfigFiles.jsonRemoving(from: data)
                }
            case .codex:
                try rewrite(codexConfig) { data in
                    let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    let next = connecting ? AIClientConfigFiles.tomlAdding(command: helper, to: text)
                        : AIClientConfigFiles.tomlRemoving(from: text)
                    return Data(next.utf8)
                }
            case .claudeCode:
                guard let cli = claudeCLI else {
                    message = L10n("Claude Code's command-line tool was not found. Copy the prompt and paste it into Claude Code instead.")
                    return
                }
                // 已经有一条的话 `add` 会失败：先删再加（删不掉 = 本来就没有，不算错）。
                _ = await Self.run(cli, ["mcp", "remove", "--scope", "user", AIClientConfigFiles.serverName])
                if connecting {
                    let status = await Self.run(cli, ["mcp", "add", "--scope", "user", AIClientConfigFiles.serverName, "--", helper])
                    guard status == 0 else { throw AIClientConfigFiles.FormatError(message: "claude mcp add exited with \(status).") }
                }
                // 只在真要加 / 要删时才动 settings.json（已经是这样就不重写；断开时没有这条就不去碰、更不新建文件）。
                let rule = AIClientConfigFiles.claudeCodeAllowRule
                let allows = AIClientConfigFiles.jsonAllows(rule: rule, in: FileManager.default.contents(atPath: claudeCodeSettings))
                if connecting != allows {
                    try rewrite(claudeCodeSettings) { data in
                        connecting ? try AIClientConfigFiles.jsonAllowing(rule: rule, in: data)
                            : try AIClientConfigFiles.jsonDisallowing(rule: rule, in: data)
                    }
                }
            }
            if !connecting {
                message = String(format: L10n("Disconnected. Restart %@ to finish."), L10n(client.title))
            } else if client == .claudeDesktop {
                message = L10n("Connected. Restart Claude Desktop so it picks up SrtFlow. It asks before each SrtFlow tool until you choose Always allow, in the prompt or for all of srtflow's tools at once in Claude's Connectors settings.")
            } else {
                message = String(
                    format: L10n("Connected. Restart %@ so it picks up SrtFlow. It will use SrtFlow's tools without asking; SrtFlow itself asks before moving files to the Trash."),
                    L10n(client.title)
                )
            }
        } catch let error as AIClientConfigFiles.FormatError {
            message = String(format: L10n("Could not update %@: %@"), L10n(client.title), error.message)
        } catch {
            message = String(format: L10n("Could not update %@: %@"), L10n(client.title), error.localizedDescription)
        }
    }

    /// 读 → 改 → 原子写回。第一次改之前备份一份原文件（`.srtflow-backup`），改坏了用户能找回来。
    private func rewrite(_ path: String, _ transform: (Data?) throws -> Data) throws {
        let fm = FileManager.default
        let original = fm.contents(atPath: path)
        let next = try transform(original)
        let backup = path + ".srtflow-backup"
        if let original, !fm.fileExists(atPath: backup) {
            try original.write(to: URL(fileURLWithPath: backup))
        }
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try next.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// 「连接」在这台机器上能不能直接接上：Claude Code 要有它的命令行，另外两家直接改配置文件、总能接。
    /// 接不上的那一行只给「复制一段话」（设置页一行只放一个按钮）。
    func canConnect(_ client: Client) -> Bool {
        client != .claudeCode || claudeCLI != nil
    }

    /// Claude Code 的命令行装在哪（官方安装器、npm、Homebrew 几个常见位置）。
    private var claudeCLI: URL? {
        [home + "/.local/bin/claude", home + "/.claude/local/claude", "/opt/homebrew/bin/claude",
         "/usr/local/bin/claude", home + "/.npm-global/bin/claude", home + "/.bun/bin/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// 跑一条命令，等它结束（用结束回调，不占着线程等）。
    private static func run(_ executable: URL, _ arguments: [String]) async -> Int32 {
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

    // MARK: 复制

    /// 「复制一段话」：贴给 Claude Code / Codex，它们自己在终端里把 SrtFlow 装上。
    func setupPrompt(for client: Client) -> String? {
        guard let helper = helperURL?.path else { return nil }
        switch client {
        case .claudeCode:
            return String(format: L10n("Please connect the SrtFlow video editor to Claude Code: run this command in the terminal, add \"mcp__srtflow\" to permissions.allow in ~/.claude/settings.json so its tools run without asking, then tell me to start a new session.\n\nclaude mcp add --scope user srtflow -- \"%@\""), helper)
        case .codex:
            return String(format: L10n("Please connect the SrtFlow video editor to Codex: run this command in the terminal, add the line default_tools_approval_mode = \"approve\" under [mcp_servers.srtflow] in ~/.codex/config.toml so its tools run without asking, then tell me to start a new session.\n\ncodex mcp add srtflow -- \"%@\""), helper)
        case .claudeDesktop:
            return nil
        }
    }

    /// 给别的 MCP 客户端（Cursor、Cherry Studio……）用的那段 JSON。
    var genericConfiguration: String? {
        guard let helper = helperURL?.path,
              let data = try? AIClientConfigFiles.jsonAdding(command: helper, to: nil) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func copy(_ text: String, confirmation: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        message = confirmation
    }
}
