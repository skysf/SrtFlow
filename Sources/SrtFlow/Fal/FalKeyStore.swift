import Foundation
import Security

// MARK: - fal.ai 的 Key 存在系统钥匙串里
//
// 管什么：方案第 17 条 —— **能添加、能删除，存系统钥匙串；删除就从钥匙串里抹掉；先只管一把 Key**。
// 一条通用密码项：服务名 = 这个 App 的 bundle id + `.fal`（测试版是另一个 bundle id，钥匙串里也是另一条），账号固定 `api-key`。
// 不管什么：调 fal（FalClient）、Key 在哪填（FalSettingsView）、什么时候读（FalKeyCache）。
//
// 2026-09-29 本机探针量出来的行为（docs/architecture/fal-generation.md「钥匙串」）：
// - **只读属性（有没有存过）不弹授权框**；读密钥本身时，只有创建这一项的那个签名能免弹窗读 —— App 是 ad-hoc 签名的，
//   **每出一个新版本签名就变了，第一次读会弹 macOS 的「要使用钥匙串里的机密信息」框**，点「始终允许」之后这一版不再弹；
// - 所以读分两档：`.silent`（`kSecUseAuthenticationUIFail`：要弹框就直接报「需要授权」，不弹）和 `.interactive`（弹框、等用户点）。
//   AI 那边先试 `.silent`，需要授权时先在横幅上说一句「macOS 马上会问是否允许」，再去弹（FalKeyCache）；
// - 读到之后 App 这次运行里记在内存里（FalKeyCache），一次运行最多弹一次。
// - 不用 data-protection 钥匙串：它要 entitlement，ad-hoc 签名的 App 用不了。

enum FalKeyStore {
    enum Access { case silent, interactive }

    enum ReadResult: Equatable {
        case key(String)
        case missing
        /// 只读了「不弹框」那档、而这一版还没被允许读：要 `.interactive` 才读得到。
        case needsPermission
        case failed(OSStatus)
    }

    struct StoreError: Error, Equatable {
        let status: OSStatus
        var message: String {
            "The macOS keychain refused (\(status): \((SecCopyErrorMessageString(status, nil) as String?) ?? "unknown error"))."
        }
    }

    static let account = "api-key"

    static var defaultService: String { (Bundle.main.bundleIdentifier ?? "com.srtflow.SrtFlow") + ".fal" }

    // MARK: 存 / 取 / 删

    /// 存过 Key 没有。**只查属性，不读密钥、不弹授权框**。
    static func hasKey(service: String = defaultService) -> Bool {
        var query = baseQuery(service)
        query[kSecReturnAttributes as String] = true
        query.merge(neverPrompt) { _, new in new }
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func read(_ access: Access, service: String = defaultService) -> ReadResult {
        var query = baseQuery(service)
        query[kSecReturnData as String] = true
        if access == .silent { query.merge(neverPrompt) { _, new in new } }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let text = String(data: data, encoding: .utf8), !text.isEmpty else { return .missing }
            return .key(text)
        case errSecItemNotFound:
            return .missing
        case errSecInteractionNotAllowed, errSecAuthFailed:
            return .needsPermission
        default:
            return .failed(status)
        }
    }

    /// 存（已经有就换掉）。传进来的话先整理（`normalized`）；整理不出一把像样的 Key 就抛错。
    static func save(_ raw: String, service: String = defaultService) throws {
        guard let key = normalized(raw) else { throw StoreError(status: errSecParam) }
        let data = Data(key.utf8)
        var status = SecItemUpdate(baseQuery(service) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery(service)
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "SrtFlow fal.ai API key"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw StoreError(status: status) }
    }

    /// 从钥匙串里抹掉。本来就没有也算成功。
    static func delete(service: String = defaultService) throws {
        let status = SecItemDelete(baseQuery(service) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StoreError(status: status) }
    }

    // MARK: 整理用户粘贴的 Key（纯）

    /// fal 的 Key 长 `<id>:<secret>`。用户常把 `Key ` 前缀、引号、首尾空白 / 换行一起粘进来：去掉；中间还有空白或太短就不收。
    static func normalized(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
        if text.lowercased().hasPrefix("key ") { text = String(text.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard text.count >= 16, !text.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
        return text
    }

    /// 「要弹授权框就直接报错、别弹」。这个常量从 macOS 11 起标了弃用（说改用 `LAContext.interactionNotAllowed`），
    /// 但 2026-09-29 探针量过：**`LAContext` 拦不住老式（文件）钥匙串的授权框**（读别的签名建的项，进程卡在框上等人点），
    /// 老常量才拦得住（直接回 -25308）。所以留着它，警告只有这一处。
    private static var neverPrompt: [String: Any] {
        [kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
    }

    private static func baseQuery(_ service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}

/// 「问 macOS 要授权」那句提示挂过没有（`willAsk` 是 @Sendable 的，不能直接改局部变量）。
final class FalPromptFlag: @unchecked Sendable {
    var value = false
}

/// 这一次运行里读到的 Key 记在内存里：一次运行最多问钥匙串一次（也就最多弹一次授权框）。
actor FalKeyCache {
    static let shared = FalKeyCache()

    private var cached: String?

    /// 取 Key。要弹授权框时先调 `willAsk`（让横幅先说一句这是什么），弹框在后台线程上等，不占主线程。
    func key(willAsk: @Sendable () async -> Void = {}) async -> FalKeyStore.ReadResult {
        if let cached { return .key(cached) }
        var result = FalKeyStore.read(.silent)
        if result == .needsPermission {
            await willAsk()
            result = await Task.detached { FalKeyStore.read(.interactive) }.value
        }
        if case .key(let text) = result { cached = text }
        return result
    }

    /// 用户刚在设置里存了 / 换了 Key：直接记下，不用再读一遍（读就可能弹框）。
    func remember(_ key: String?) { cached = key }
}
