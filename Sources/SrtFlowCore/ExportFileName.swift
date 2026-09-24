import Foundation

/// 导出面板「标题」→ 文件名主干。扩展名不归用户填（面板上用灰字跟在后面），
/// 这里只管主干。约束见 docs/architecture/export-settings.md。
public enum ExportFileName {

    /// - 去掉首尾空白；
    /// - `/` 和 `:` 换成 `-`：前者是路径分隔符，后者在 Finder 里显示成 `/`；
    /// - 用户顺手把扩展名也打进来（`L12.mp4`）就剥掉，免得变成 `L12.mp4.mp4`；
    /// - 去掉开头的 `.`，不然成了隐藏文件；
    /// - 什么都不剩就用 `fallback`（调用方保证它本身能当文件名）。
    public static func stem(
        from title: String, droppingExtension pathExtension: String, fallback: String
    ) -> String {
        var stem = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let suffix = "." + pathExtension.lowercased()
        if !pathExtension.isEmpty, stem.lowercased().hasSuffix(suffix) {
            stem = String(stem.dropLast(suffix.count))
        }
        while stem.hasPrefix(".") { stem.removeFirst() }
        stem = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        return stem.isEmpty ? fallback : stem
    }
}
