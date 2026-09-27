import Foundation

/// 做出来的文件叫什么：导出面板「标题」→ 文件名主干，以及撞名时怎么加编号。扩展名不归用户填
/// （面板上用灰字跟在后面）。约束见 docs/architecture/export-settings.md 第五节。
public enum ExportFileName {

    /// 撞名不覆盖、也不问：`名字.后缀` 占了就 `名字 2.后缀`、`名字 3.后缀`……
    /// 用它的：批量转换字幕、压缩 / 烧录页的成品、AI 做出来的文件和替没存过的工程存的盘 —— 规则只有这一份。
    /// （剪辑导出不走这里：那边是先提示、再确认替换。）`exists` 由调用方给：硬盘上有的，加上它自己知道
    /// 马上要写的（队列里别的条目、同一批前面用掉的名字）。
    public static func unoccupied(
        in folder: URL, stem: String, pathExtension: String, exists: (URL) -> Bool
    ) -> URL {
        var candidate = folder.appendingPathComponent(stem).appendingPathExtension(pathExtension)
        var number = 2
        while exists(candidate) {
            candidate = folder.appendingPathComponent("\(stem) \(number)").appendingPathExtension(pathExtension)
            number += 1
        }
        return candidate
    }

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
