import CoreText
import Foundation

struct SubtitleFont: Identifiable, Hashable, Sendable {
    var id: String { familyName }
    var familyName: String
    var fileURL: URL
    var supportsChinese: Bool
}

/// 列出**libass 真能用**的字体。
///
/// 这一步不能省。macOS 的苹方等系统中文字体放在
/// `/System/Library/PrivateFrameworks/FontServices.framework/Resources/Reserved/`
/// 里，普通进程读不了，libass 打开会失败，然后 fontconfig 悄悄换成另一个字体 ——
/// 用户以为选了苹方，烧出来却是别的字。所以这里只收「文件可读 + CoreText 能解析」
/// 的字体，再把字体文件软链进任务目录、用 `fontsdir` 指过去，保证选什么就是什么。
enum FontCatalog {

    /// 用这几个字判断字体有没有中文字形。
    private static let chineseProbe = CharacterSet(charactersIn: "中文字幕测试的一二三")

    private static let searchDirectories: [String] = [
        "/System/Library/Fonts",
        "/System/Library/Fonts/Supplemental",
        "/Library/Fonts",
        NSString(string: "~/Library/Fonts").expandingTildeInPath
    ]

    private static let fontExtensions: Set<String> = ["ttf", "ttc", "otf", "otc"]

    static func scan() -> [SubtitleFont] {
        var byFamily: [String: SubtitleFont] = [:]

        for directory in searchDirectories {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { continue }
            for name in names {
                guard fontExtensions.contains((name as NSString).pathExtension.lowercased()) else { continue }
                let path = directory + "/" + name
                guard FileManager.default.isReadableFile(atPath: path) else { continue }
                let url = URL(fileURLWithPath: path)
                guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] else { continue }

                for descriptor in descriptors {
                    guard let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String,
                          // 以点开头的是系统内部字体（.LastResort 之类），不该出现在选择列表里。
                          !family.hasPrefix("."),
                          !family.isEmpty else { continue }

                    let font = CTFontCreateWithFontDescriptor(descriptor, 24, nil)
                    let characterSet = CTFontCopyCharacterSet(font) as CharacterSet
                    let supportsChinese = characterSet.isSuperset(of: chineseProbe)

                    if let existing = byFamily[family] {
                        // 同一字体族出现在多个文件里时，留下支持中文的那份。
                        if supportsChinese && !existing.supportsChinese {
                            byFamily[family] = SubtitleFont(familyName: family, fileURL: url, supportsChinese: true)
                        }
                    } else {
                        byFamily[family] = SubtitleFont(
                            familyName: family,
                            fileURL: url,
                            supportsChinese: supportsChinese
                        )
                    }
                }
            }
        }

        return byFamily.values.sorted {
            // 支持中文的排前面，其余按名字排。
            if $0.supportsChinese != $1.supportsChinese { return $0.supportsChinese }
            return $0.familyName.localizedStandardCompare($1.familyName) == .orderedAscending
        }
    }

    /// 挑一个合适的默认字体：优先常见的中文黑体。
    static func preferredDefault(in fonts: [SubtitleFont]) -> SubtitleFont? {
        let preferred = [
            "Hiragino Sans GB", "Heiti SC", "PingFang SC", "Source Han Sans CN",
            "Noto Sans SC", "Microsoft YaHei", "Songti SC", "Helvetica Neue", "Helvetica", "Arial"
        ]
        for name in preferred {
            if let match = fonts.first(where: { $0.familyName == name }) { return match }
        }
        return fonts.first(where: \.supportsChinese) ?? fonts.first
    }
}

/// 字体扫描要遍历几百个字体文件、逐个问 CoreText，别放在主线程上做。
@MainActor
final class FontCatalogStore: ObservableObject {
    @Published private(set) var fonts: [SubtitleFont] = []
    @Published private(set) var isLoading = true

    static let shared = FontCatalogStore()

    private init() {}

    func loadIfNeeded() {
        guard isLoading, fonts.isEmpty else { return }
        Task {
            let scanned = await Task.detached(priority: .userInitiated) { FontCatalog.scan() }.value
            self.fonts = scanned
            self.isLoading = false
        }
    }

    func font(named name: String) -> SubtitleFont? {
        fonts.first { $0.familyName == name }
    }

    var chineseCapableFonts: [SubtitleFont] { fonts.filter(\.supportsChinese) }
    var otherFonts: [SubtitleFont] { fonts.filter { !$0.supportsChinese } }
}
