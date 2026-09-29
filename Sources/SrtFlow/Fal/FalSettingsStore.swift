import Combine
import Foundation
import SrtFlowMCPKit

// MARK: - fal 的设置和今天花了多少（存本机）
//
// 管什么：设置里「AI」一节的 fal 部分背后的状态 —— 每日上限（默认 10 美元，方案第 18 条）、用户改过的模型（每种事一个，方案第 19 条）、
// 按天记的花费、有没有存 Key（只查钥匙串的属性，不读密钥）；Key 添加 / 删除时同步「配了哪些生成提供方」的小文件（`MCPProviderMarker`，
// 小程序据此决定列不列 generate_media，方案第 36 条）。
// 不管什么：Key 怎么存（FalKeyStore）、怎么估价和判断问不问（FalModels / FalSpendPolicy）、界面（FalSettingsView）。
//
// 存在 UserDefaults 里（几十字节的 JSON）：不是机密；钱数是估算，丢了也只是从零算。

struct FalSettings: Codable, Equatable {
    static let defaultDailyLimit = 10.0
    static let maxDailyLimit = 100_000.0

    var dailyLimit = FalSettings.defaultDailyLimit
    /// 用户改过的模型：键是 `FalModel.Kind` 的原始值；没改的种类走登记表。
    var overrides: [String: FalModel] = [:]

    init() {}

    /// 读得宽：存的是用户设置，缺的字段走默认，别因为一个字段读不出来就丢掉整份。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let limit = try container.decodeIfPresent(Double.self, forKey: .dailyLimit) ?? Self.defaultDailyLimit
        dailyLimit = Self.clamped(limit)
        overrides = (try? container.decodeIfPresent([String: FalModel].self, forKey: .overrides)) ?? [:]
    }

    static func clamped(_ limit: Double) -> Double {
        guard limit.isFinite else { return defaultDailyLimit }
        return min(max(limit, 0), maxDailyLimit)
    }

    func model(for kind: FalModel.Kind) -> FalModel {
        FalModels.preset(for: kind, overrides: overrides(kind))
    }

    /// 这一种事被用户改成了哪个（没改就是空）。
    func overrides(_ kind: FalModel.Kind) -> [FalModel.Kind: FalModel] {
        overrides[kind.rawValue].map { [kind: $0] } ?? [:]
    }
}

@MainActor
final class FalSettingsStore: ObservableObject {
    static let shared = FalSettingsStore()

    static let settingsKey = "SrtFlow.fal.settings.v1"
    static let ledgerKey = "SrtFlow.fal.spend.v1"

    @Published private(set) var settings: FalSettings
    @Published private(set) var ledger: FalSpendLedger
    @Published private(set) var hasKey: Bool
    /// 设置页上那一句状态 / 错误（存 Key 失败之类）。
    @Published private(set) var message: String?

    private let defaults: UserDefaults
    private let providersURL: URL
    private let keyService: String

    init(
        defaults: UserDefaults = .standard,
        keyService: String = FalKeyStore.defaultService,
        providersURL: URL = FalSettingsStore.defaultProvidersURL()
    ) {
        self.defaults = defaults
        self.keyService = keyService
        self.providersURL = providersURL
        settings = defaults.data(forKey: Self.settingsKey).flatMap { try? JSONDecoder().decode(FalSettings.self, from: $0) } ?? FalSettings()
        ledger = defaults.data(forKey: Self.ledgerKey).flatMap { try? JSONDecoder().decode(FalSpendLedger.self, from: $0) } ?? FalSpendLedger()
        hasKey = FalKeyStore.hasKey(service: keyService)
    }

    /// 和小程序约定的那个小文件（自检 / 冒烟用 `SRTFLOW_MCP_PROVIDERS` 换地方，同小程序那一头）。
    nonisolated static func defaultProvidersURL() -> URL {
        if let path = ProcessInfo.processInfo.environment["SRTFLOW_MCP_PROVIDERS"] { return URL(fileURLWithPath: path) }
        return MCPProviderMarker.url(bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.srtflow.SrtFlow")
    }

    // MARK: 上限、模型

    var dailyLimit: Double { settings.dailyLimit }

    func setDailyLimit(_ limit: Double) {
        var next = settings
        next.dailyLimit = FalSettings.clamped(limit)
        update(next)
    }

    func model(for kind: FalModel.Kind) -> FalModel { settings.model(for: kind) }

    var overriddenModels: [FalModel.Kind: FalModel] {
        Dictionary(uniqueKeysWithValues: settings.overrides.compactMap { key, model in FalModel.Kind(rawValue: key).map { ($0, model) } })
    }

    /// 换成自己的模型（端点号 + 每个单位的单价）；`nil` = 改回预设。端点号不合规、单价不是正数就不改，回一句话。
    @discardableResult
    func setModel(kind: FalModel.Kind, endpoint: String, unitPrice: Double?) -> String? {
        let trimmed = endpoint.trimmingCharacters(in: .whitespaces)
        guard FalModels.isValidEndpoint(trimmed) else { return report(L10n("That is not a fal.ai endpoint id. It looks like owner/model-name.")) }
        if let unitPrice, !(unitPrice.isFinite && unitPrice >= 0) { return report(L10n("The price must be a number.")) }
        var next = settings
        // 登记过的模型、价格没动（或没填）：还是登记的那个（按分辨率分档的价也跟着）；价格改了 = 用户自己的模型，一个价格管所有档。
        if let registered = FalModels.known(trimmed), registered.kind == kind, unitPrice == nil || unitPrice == registered.unitPrice {
            next.overrides[kind.rawValue] = registered == FalModels.preset(for: kind) ? nil : registered
        } else {
            next.overrides[kind.rawValue] = FalModel(kind: kind, endpoint: trimmed, title: trimmed, unitPrice: unitPrice)
        }
        message = nil
        update(next)
        return nil
    }

    func resetModel(kind: FalModel.Kind) {
        var next = settings
        next.overrides[kind.rawValue] = nil
        update(next)
    }

    // MARK: 花费

    func spentToday(now: Date = Date()) -> Double { ledger.spent(on: now) }

    func decide(estimate: Double?, now: Date = Date()) -> FalSpendPolicy.Decision {
        FalSpendPolicy.decide(estimate: estimate, spentToday: spentToday(now: now), dailyLimit: dailyLimit)
    }

    /// 提交生成时记上这一笔（估算）；生成失败 / 取消时用 `refund` 退回。
    func recordSpend(_ amount: Double, now: Date = Date()) {
        var next = ledger
        next.add(amount, on: now)
        next.prune(now: now)
        saveLedger(next)
    }

    func refundSpend(_ amount: Double, on day: Date) {
        var next = ledger
        next.refund(amount, on: day)
        saveLedger(next)
    }

    // MARK: Key

    /// 存 Key（粘进来的先整理）。成功回 nil，失败回一句话。
    @discardableResult
    func saveKey(_ raw: String) -> String? {
        guard let key = FalKeyStore.normalized(raw) else {
            return report(L10n("That does not look like a fal.ai API key. Copy the whole key from fal.ai/dashboard/keys."))
        }
        do {
            try FalKeyStore.save(key, service: keyService)
        } catch {
            return report((error as? FalKeyStore.StoreError)?.message ?? error.localizedDescription)
        }
        Task { await FalKeyCache.shared.remember(key) }
        hasKey = true
        message = nil
        syncProviders()
        return nil
    }

    @discardableResult
    func removeKey() -> String? {
        do {
            try FalKeyStore.delete(service: keyService)
        } catch {
            return report((error as? FalKeyStore.StoreError)?.message ?? error.localizedDescription)
        }
        Task { await FalKeyCache.shared.remember(nil) }
        hasKey = false
        message = nil
        syncProviders()
        return nil
    }

    /// 重新看一眼钥匙串里有没有（设置页出现时、启动时）。
    func refreshKeyStatus() {
        let now = FalKeyStore.hasKey(service: keyService)
        if now != hasKey { hasKey = now }
        syncProviders()
    }

    /// 把「配了 fal」写进和小程序约定的小文件：只在内容变了才写。App 每次启动也调一遍（文件被删了、Key 是别的途径删的）。
    func syncProviders() {
        do {
            try MCPProviderMarker.write(hasKey ? [.fal] : [], to: providersURL)
        } catch {
            FileHandle.standardError.write(Data("SrtFlow fal: could not write \(providersURL.path): \(error)\n".utf8))
        }
    }

    /// 设置页上挂一句话（填的东西不对）。
    func warn(_ text: String) { message = text }

    // MARK: 私有

    private func report(_ text: String) -> String {
        message = text
        return text
    }

    private func update(_ next: FalSettings) {
        guard next != settings else { return }
        settings = next
        if let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: Self.settingsKey) }
    }

    private func saveLedger(_ next: FalSpendLedger) {
        guard next != ledger else { return }
        ledger = next
        if let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: Self.ledgerKey) }
    }
}
