import AppKit
import Foundation
import UniformTypeIdentifiers

// 滤镜段的剪切板。
//
// 走**系统剪贴板**而不是 App 内部的一个变量：跨工程粘贴因此天然成立（复制一段
// 调好的滤镜，开另一个工程直接粘上去），也不用自己管生命周期。
//
// 用自己的类型标识，**不写纯文本**：写了的话复制一段滤镜会把用户剪贴板里的文字
// 换成一串 JSON，⌘V 到别处粘出一坨乱码。代价是在别的 App 里粘不出东西 ——
// 那本来也没有意义。
//
// 类型标识和 `FilterDrag` 的**不是同一个**：那个是拖卡片用的（载荷只是预设名），
// 这个带着强度和时长。同一个标识两种载荷，迟早有人读错。
enum FilterClipboard {
    static let typeIdentifier = FilterPayloadType.clipboard
    static let type = UTType(exportedAs: typeIdentifier, conformingTo: .data)
    static let pasteboardType = NSPasteboard.PasteboardType(typeIdentifier)

    /// 复制下来的是「这是一段什么样的滤镜」，**不含它原来在哪**：
    /// 粘贴的落点由播放头决定（和按 `+` 同一套规则），层号由落点现算 ——
    /// 原来的层号在另一个工程里可能根本不存在。
    struct Payload: Codable, Equatable {
        var preset: FilterPreset
        var strength: Double
        var duration: Double

        init(_ filter: FilterClip) {
            preset = filter.preset
            strength = filter.strength
            duration = filter.duration
        }
    }

    static func data(for filter: FilterClip) -> Data? {
        try? JSONEncoder().encode(Payload(filter))
    }

    /// 写进系统剪贴板。
    ///
    /// **自己写一遍**而不是只靠 `onCopyCommand` 返回的 item provider：那条路
    /// 什么时候、以什么形式落盘由 SwiftUI 决定，而 `read()` 要的是能**同步**读到
    /// 的字节（粘贴那一拍没法等异步加载）。两边写的是同一份数据，谁后写都一样。
    @discardableResult
    static func write(_ filter: FilterClip) -> Bool {
        guard let data = data(for: filter) else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setData(data, forType: pasteboardType)
    }

    static func itemProvider(for filter: FilterClip) -> NSItemProvider? {
        guard let data = data(for: filter) else { return nil }
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: typeIdentifier, visibility: .all) {
            completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    /// 剪贴板里此刻有没有一段滤镜。菜单项的亮灭看它。
    static func read() -> Payload? {
        guard let data = NSPasteboard.general.data(forType: pasteboardType) else { return nil }
        return try? JSONDecoder().decode(Payload.self, from: data)
    }
}
