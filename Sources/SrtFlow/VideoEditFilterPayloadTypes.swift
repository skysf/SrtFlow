import Foundation

/// 滤镜卡片拖放的类型标识。
///
/// 2026-09-26 之前这里还有第二个（剪贴板里的一段滤镜，`com.srtflow.filter-clip`）：滤镜段的复制粘贴
/// 并进了时间线的剪贴板（`TimelineClipboard`，`com.srtflow.timeline-items`，每一样都是完整的一份），
/// 那个标识连同 Info.plist 里的声明一起删了。拖卡片的载荷只是预设名，和剪贴板的载荷不是一回事 ——
/// 别拿同一个标识装两种载荷。
enum FilterPayloadType {
    /// 从滤镜库拖一张卡片到时间线。载荷是预设的 rawValue。
    static let drag = "com.srtflow.filter"
}
