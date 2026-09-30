import SwiftUI

/// 界面语言。默认跟随系统，也可以强制成某一种。
///
/// **加一种语言只做两件事**：这里加一个 case（rawValue 就是 `.lproj` 的名字），再补
/// 一套字符串表（`Sources/SrtFlow/Resources/<code>.lproj/`）。locale、AppKit 的启动
/// 语言、查表用的 bundle、音频库按语言选标题，都从 rawValue 推出来，不用再改别处。
/// 流程见 docs/architecture/localization.md「加一种界面语言」。
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    /// 菜单里显示的名字。**故意不做本地化**（调用处用 `Text(verbatim:)`）：选项本身
    /// 要用它代表的那种语言写，这样界面现在是哪一种语言，用户都能认出自己要的那一项。
    var nativeName: String {
        switch self {
        case .system: return "System"
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        }
    }

    /// 传给 SwiftUI 环境的 locale。跟随系统时返回 nil，交给系统自己决定。
    var locale: Locale? {
        self == .system ? nil : Locale(identifier: rawValue)
    }

    /// 实际生效的语言代码：跟随系统时就是系统在 App 的语言里挑中的那个
    /// （包里没有的语言退回 en）。代码里要「按语言分支」的地方（音频库的中文标题）
    /// 只看这个，和 `L10n` 的查表口径一致。
    var resolvedCode: String {
        self == .system ? (Bundle.main.preferredLocalizations.first ?? "en") : rawValue
    }

    /// 查字符串表用的 bundle。
    ///
    /// 不能直接拿语言代码去 `path(forResource:ofType:)`：SwiftPM 组装资源包时会把
    /// 本地化目录名转成小写（`zh-Hans` → `zh-hans.lproj`），而这个查找是区分
    /// 大小写的，直接查会落空、悄悄退回英文。所以先从 `Bundle.main.localizations`
    /// 里按实际存在的名字做不区分大小写的匹配。
    var bundle: Bundle {
        guard self != .system else { return .main }
        let available = Bundle.main.localizations
        let match = available.first { $0.caseInsensitiveCompare(rawValue) == .orderedSame }
            // 退一步按语言主码匹配（zh 对上 zh-hans）。
            ?? available.first { $0.lowercased().hasPrefix(rawValue.prefix(2).lowercased()) }
        guard let name = match,
              let path = Bundle.main.path(forResource: name, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return .main }
        return bundle
    }
}

/// 当前语言的一份线程安全快照。
///
/// `L10n(_:)` 会在非主线程被调用（错误描述、格式化工具都可能在后台线程求值），
/// 而 `AppLanguageStore` 绑在主 actor 上，不能直接读。这里存一份不受 actor
/// 约束的副本，随选择更新。
private final class LanguageSnapshot: @unchecked Sendable {
    static let shared = LanguageSnapshot()

    private let lock = NSLock()
    private var value: AppLanguage = .system

    var current: AppLanguage {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ language: AppLanguage) {
        lock.lock()
        value = language
        lock.unlock()
    }
}

@MainActor
final class AppLanguageStore: ObservableObject {
    static let shared = AppLanguageStore()

    private let storageKey = "appLanguage"

    @Published var language: AppLanguage {
        didSet {
            guard oldValue != language else { return }
            LanguageSnapshot.shared.set(language)
            UserDefaults.standard.set(language.rawValue, forKey: storageKey)
            applyToAppKit()
        }
    }

    private init() {
        let stored = UserDefaults.standard.string(forKey: storageKey) ?? AppLanguage.system.rawValue
        let resolved = AppLanguage(rawValue: stored) ?? .system
        language = resolved
        LanguageSnapshot.shared.set(resolved)
    }

    /// SwiftUI 里的 `Text` 会跟着环境 locale 立刻切换，但菜单栏、文件选择面板这些
    /// 由 AppKit 提供的部分只认启动时的 AppleLanguages。这里把选择写进去，
    /// 下次启动整个 App 就一致了。
    private func applyToAppKit() {
        if language == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
        }
    }

    /// 菜单栏等 AppKit 部件要重启才会跟着变，界面上据此提示一句。
    var needsRestartForMenus: Bool {
        guard language != .system else { return false }
        let systemFirst = Bundle.main.preferredLocalizations.first ?? "en"
        return !systemFirst.hasPrefix(language.rawValue.prefix(2))
    }
}

/// 按当前选择的语言查字符串表。
///
/// 不能直接用 `NSLocalizedString`：它只认系统语言，不认应用内的选择。SwiftUI 的
/// `Text(LocalizedStringKey)` 走环境 locale，而这个函数负责代码里拼字符串的地方，
/// 两边查的是同一份 .strings。
func L10n(_ key: String) -> String {
    let bundle = LanguageSnapshot.shared.current.bundle
    let value = bundle.localizedString(forKey: key, value: nil, table: nil)
    // 选中的语言里没有这条，就退回主 bundle（等价于系统语言 / 英文原文）。
    return value == key ? Bundle.main.localizedString(forKey: key, value: key, table: nil) : value
}

extension View {
    /// 把所选语言注入环境，`Text` 的本地化查表立刻跟着切换。
    func appLanguage() -> some View {
        modifier(AppLanguageModifier())
    }
}

private struct AppLanguageModifier: ViewModifier {
    @ObservedObject private var store = AppLanguageStore.shared

    func body(content: Content) -> some View {
        let _ = PerfCounters.body(Self.self)
        if let locale = store.language.locale {
            content.environment(\.locale, locale)
        } else {
            content
        }
    }
}

/// 语言选择控件，首页和「设置」里都用它。
struct AppLanguagePicker: View {
    @ObservedObject private var store = AppLanguageStore.shared
    var showsLabel = true

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        Picker(selection: $store.language) {
            ForEach(AppLanguage.allCases) { option in
                Text(verbatim: option.nativeName).tag(option)
            }
        } label: {
            if showsLabel {
                Text("Language")
            }
        }
    }
}
