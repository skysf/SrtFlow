import SwiftUI

// MARK: - 设置里的「AI」一节
//
// 管什么：三个客户端各一行（连没连 + 连接 / 断开 / 复制一段话），外加给别的客户端的配置。
// 不管什么：配置文件怎么改（AIClientSetup / AIClientConfigFiles）。

struct AIConnectSection: View {
    @ObservedObject private var setup = AIClientSetup.shared

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        Section("AI") {
            Text("Let AI apps such as Claude and Codex edit videos in SrtFlow. You watch every step in the editor, and Command-Z undoes any of it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if setup.helperURL == nil {
                Text("This copy of SrtFlow has no AI helper inside, so AI apps cannot connect to it.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(AIClientSetup.Client.allCases) { client in
                    AIClientRow(client: client)
                }
                HStack {
                    Spacer()
                    Button("Copy Setup for Other Apps") {
                        if let text = setup.genericConfiguration {
                            setup.copy(text, confirmation: L10n("Copied the configuration."))
                        }
                    }
                    .instantHelp("Copy the MCP configuration (JSON) for apps such as Cursor or Cherry Studio")
                }
            }
            if let message = setup.message {
                Text(verbatim: message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .onAppear { setup.refresh() }
    }
}

private struct AIClientRow: View {
    let client: AIClientSetup.Client
    @ObservedObject private var setup = AIClientSetup.shared

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        let status = setup.statuses[client] ?? .notInstalled
        LabeledContent {
            HStack(spacing: 6) {
                statusLabel(status)
                if let prompt = setup.setupPrompt(for: client) {
                    Button("Copy Prompt") {
                        setup.copy(prompt, confirmation: String(format: L10n("Copied. Paste it into %@."), L10n(client.title)))
                    }
                    .instantHelp("Copy a message you can paste into this app so it connects SrtFlow itself")
                }
                if status == .connected {
                    Button("Disconnect") { Task { await setup.disconnect(client) } }
                        .instantHelp("Remove SrtFlow from this app's MCP settings")
                } else if status != .notInstalled {
                    Button("Connect") { Task { await setup.connect(client) } }
                        .instantHelp("Add SrtFlow to this app's MCP settings")
                }
            }
            .controlSize(.small)
            .disabled(setup.busy != nil)
        } label: {
            Text(LocalizedStringKey(client.title))
        }
    }

    @ViewBuilder
    private func statusLabel(_ status: AIClientSetup.Status) -> some View {
        switch status {
        case .connected:
            Text("Connected").foregroundStyle(.green)
        case .connectedElsewhere:
            Text("Connected to another copy").foregroundStyle(.orange)
        case .notConnected:
            Text("Not connected").foregroundStyle(.secondary)
        case .notInstalled:
            Text("Not installed").foregroundStyle(.tertiary)
        }
    }
}
