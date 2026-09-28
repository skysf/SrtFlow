import SwiftUI

// MARK: - 设置里的「AI」一节
//
// 管什么：三个客户端各一行（连没连 + 一个按钮：连上了是「断开」，没连上 / 每次都会问是「连接」，「连接」在这台机器上
// 用不了时换成「复制一段话」—— 2026-09-28 用户：没连上的时候不该显示断开，精简下），外加给别的客户端的配置；
// 用户同意过、AI 读起来不再问的地方（AIReadGrants），一条一行、可以删；用户自己的剪辑风格（AIRecipeSettingsList）；
// SrtFlow 自己的配音声音下没下（KokoroVoiceSettingsRow）。
// 不管什么：配置文件怎么改（AIClientSetup / AIClientConfigFiles）、什么时候问（AIWorkspace）。

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
                AIReadGrantsList()
                AIRecipesList()
                KokoroVoiceSettingsRow()
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
                action(for: status)
            }
            .controlSize(.small)
            .disabled(setup.busy != nil)
        } label: {
            Text(LocalizedStringKey(client.title))
        }
    }

    /// 一行只放一个按钮。
    @ViewBuilder
    private func action(for status: AIClientSetup.Status) -> some View {
        switch status {
        case .notInstalled:
            EmptyView()
        case .connected:
            Button("Disconnect") { Task { await setup.disconnect(client) } }
                .instantHelp("Remove SrtFlow from this app's MCP settings")
        case .notConnected, .connectedAsking, .connectedElsewhere:
            if setup.canConnect(client) {
                Button("Connect") { Task { await setup.connect(client) } }
                    .instantHelp("Add SrtFlow to this app's MCP settings and let it use SrtFlow's tools without asking")
            } else if let prompt = setup.setupPrompt(for: client) {
                Button("Copy Prompt") {
                    setup.copy(prompt, confirmation: String(format: L10n("Copied. Paste it into %@."), L10n(client.title)))
                }
                .instantHelp("Copy a message you can paste into this app so it connects SrtFlow itself")
            }
        }
    }

    @ViewBuilder
    private func statusLabel(_ status: AIClientSetup.Status) -> some View {
        switch status {
        case .connected:
            Text("Connected").foregroundStyle(.green)
        case .connectedAsking:
            Text("Connected · asks each time").foregroundStyle(.orange)
        case .connectedElsewhere:
            Text("Connected to another copy").foregroundStyle(.orange)
        case .notConnected:
            Text("Not connected").foregroundStyle(.secondary)
        case .notInstalled:
            Text("Not installed").foregroundStyle(.tertiary)
        }
    }
}

/// 用户在对话里同意过「读这个文件」之后记下的地方：AI 再读这里的文件不问（方案第 34 条）。删一条 = 下次再问。
private struct AIReadGrantsList: View {
    @ObservedObject private var grants = AIReadGrants.shared

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        if !grants.paths.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("AI may also read these places without asking, because you allowed it once:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(grants.paths, id: \.self) { path in
                    HStack(spacing: 6) {
                        Text(verbatim: (path as NSString).abbreviatingWithTildeInPath)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Button("Forget") { grants.remove(path) }
                            .controlSize(.small)
                            .instantHelp("Ask again before AI reads files here")
                    }
                }
            }
        }
    }
}
