import Foundation

/// 滤镜有**两种**载荷，各有各的类型标识。
///
/// 放在同一个地方是为了一眼看出它们不一样：同一个标识两种载荷，迟早有人把拖卡片
/// 的载荷（只有预设名）当成剪贴板的载荷（带强度和时长）去解，解出来是空的。
/// `checks/Filters` 里有一条断言钉着这件事。
enum FilterPayloadType {
    /// 从滤镜库拖一张卡片到时间线。载荷是预设的 rawValue。
    static let drag = "com.srtflow.filter"
    /// 剪贴板里的一段滤镜。载荷是 `FilterClipboard.Payload` 的 JSON。
    static let clipboard = "com.srtflow.filter-clip"
}
