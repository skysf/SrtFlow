import SwiftUI

// MARK: - 设置 → AI 里的 fal.ai 一节
//
// 管什么：方案第 17、18、19 条的界面 —— fal 的 Key（能添加、能删除，存系统钥匙串）、每日上限（默认 10 美元，能自己改）、
// 今天已经花了多少（估算）、每种事用哪个模型（预设几个最新的，能改成自己的端点号和单价）。
// 只订阅 `FalSettingsStore`（一个小对象），不读工程。
// 不管什么：Key 怎么存 / 钱怎么记（FalSettingsStore、FalKeyStore）、生成（FalGenerationRun）。
//
// **检查器的窄栏规矩不适用这里**（设置窗口是宽的），但一行还是别写死宽度：文本框只给一个够用的最小宽度。

struct FalSettingsRow: View {
    @ObservedObject private var store = FalSettingsStore.shared
    @State private var keyText = ""
    @State private var limitText = ""
    @State private var showModels = false

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent {
                keyControls.controlSize(.small)
            } label: {
                Text(verbatim: "fal.ai")
            }
            Text("Lets AI apps make images, video clips, music and sound effects, and speak narration with fal.ai's voices, using your own fal.ai account. It costs money on that account: SrtFlow stays within the daily limit below and asks you before going over it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if store.hasKey {
                limitRow
                DisclosureGroup(isExpanded: $showModels) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(FalModel.Kind.allCases, id: \.self) { kind in
                            FalModelRow(kind: kind)
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text("fal.ai models")
                }
            }
            if let message = store.message {
                Text(verbatim: message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .onAppear {
            store.refreshKeyStatus()
            limitText = Self.limitString(store.dailyLimit)
        }
    }

    // MARK: Key

    @ViewBuilder
    private var keyControls: some View {
        if store.hasKey {
            HStack(spacing: 6) {
                Text("Key saved in the keychain").foregroundStyle(.green)
                Button("Remove Key") { store.removeKey() }
                    .instantHelp("Remove the fal.ai key from the macOS keychain; AI apps then lose the fal.ai tools")
            }
        } else {
            HStack(spacing: 6) {
                SecureField("fal.ai API key", text: $keyText)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 140)
                    .onSubmit(saveKey)
                Button("Save Key", action: saveKey)
                    .disabled(FalKeyStore.normalized(keyText) == nil)
                    .instantHelp("Store the key in the macOS keychain (fal.ai/dashboard/keys)")
            }
        }
    }

    private func saveKey() {
        guard store.saveKey(keyText) == nil else { return }
        keyText = ""
    }

    // MARK: 每日上限

    private var limitRow: some View {
        LabeledContent {
            HStack(spacing: 4) {
                Text(verbatim: "$")
                TextField("Daily limit", text: $limitText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)
                    .multilineTextAlignment(.trailing)
                    .onSubmit(commitLimit)
                Text(verbatim: "·").foregroundStyle(.tertiary)
                Text("Spent today \(FalMoney.text(store.spentToday()))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .controlSize(.small)
        } label: {
            Text("Daily limit")
        }
        .instantHelp("SrtFlow asks before AI spends more than this in one day (an estimate from each model's price, not fal.ai's bill)")
        .onDisappear(perform: commitLimit)
    }

    private func commitLimit() {
        let cleaned = limitText.trimmingCharacters(in: CharacterSet(charactersIn: "$ ")).replacingOccurrences(of: ",", with: ".")
        if let value = Double(cleaned) { store.setDailyLimit(value) }
        limitText = Self.limitString(store.dailyLimit)
    }

    static func limitString(_ limit: Double) -> String {
        limit == limit.rounded() ? String(Int(limit)) : String(format: "%.2f", limit)
    }
}

/// 一种事用哪个模型：端点号 + 每个单位的单价。改成和预设不一样的就存下来，「恢复」改回预设。
private struct FalModelRow: View {
    let kind: FalModel.Kind
    @ObservedObject private var store = FalSettingsStore.shared
    @State private var endpoint = ""
    @State private var price = ""

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        let current = store.model(for: kind)
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(Self.title(kind))
                Spacer(minLength: 8)
                if store.settings.overrides[kind.rawValue] != nil {
                    Button("Reset") { store.resetModel(kind: kind); load() }
                        .controlSize(.small)
                        .instantHelp("Go back to the model SrtFlow picked for this")
                }
            }
            HStack(spacing: 6) {
                TextField("owner/model-name", text: $endpoint)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(commit)
                Text(verbatim: "$")
                TextField("price", text: $price)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)
                    .multilineTextAlignment(.trailing)
                    .onSubmit(commit)
            }
            .controlSize(.small)
            Text(Self.unitText(kind, tiered: !current.tierPrices.isEmpty))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .onAppear(perform: load)
    }

    private func load() {
        let model = store.model(for: kind)
        endpoint = model.endpoint
        price = model.unitPrice.map(Self.priceString) ?? ""
    }

    private func commit() {
        let cleaned = price.trimmingCharacters(in: CharacterSet(charactersIn: "$ ")).replacingOccurrences(of: ",", with: ".")
        let value: Double? = cleaned.isEmpty ? nil : Double(cleaned)
        if !cleaned.isEmpty, value == nil {
            store.warn(L10n("The price must be a number."))
            load()
            return
        }
        store.setModel(kind: kind, endpoint: endpoint, unitPrice: value)
        load()
    }

    static func priceString(_ price: Double) -> String {
        var text = String(format: "%.4f", price)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    static func title(_ kind: FalModel.Kind) -> LocalizedStringKey {
        switch kind {
        case .image: return "Image"
        case .imageToVideo: return "Video from a picture"
        case .textToVideo: return "Video from text"
        case .voice: return "Narration voice"
        case .voiceClone: return "Voice cloning"
        case .music: return "Music"
        case .soundEffect: return "Sound effects"
        }
    }

    static func unitText(_ kind: FalModel.Kind, tiered: Bool) -> LocalizedStringKey {
        switch kind.unit {
        case .image: return "USD per image"
        case .videoSecond: return tiered ? "USD per second of video at 768p (the built-in model has its own prices for 480p and 1080p)" : "USD per second of video"
        case .thousandCharacters: return "USD per 1000 characters"
        case .audioSecond: return "USD per second of sound"
        case .audioMinute: return "USD per minute of sound (a started minute counts as a whole one)"
        }
    }
}
