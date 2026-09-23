import SwiftUI
import UniformTypeIdentifiers

// 时间线上**唯一**的拖放落点。
//
// 从 Finder 拖进来的文件，和 App 内的滤镜 / 音频库 / 转场三种卡片，全挂在这
// **一个**代理上，按载荷分派给各自原来的代理（那三个代理一行没改）。
// **时间线里不许再挂第二个 `.onDrop`**，`checks/timeline-drag-wiring.sh` 数着。
//
// 为什么只能有一个（2026-09-23 用探针实测，规则和证据见
// docs/architecture/timeline-drag-gestures.md §5e-2）：SwiftUI 把一次拖放交给
// 指针底下**最里面**那个落点，类型对不上也不往外找 —— 连 `.onDrop(of: [])`
// 这种空类型的都照样独占。于是任何两个落点只要一里一外叠着，里面那个就会把
// 外面那个该接的拖入吞掉：
//
// - 文件落点挂在外面：从 Finder 拖进来的文件被滤镜 / 音频库两个落点吞掉，
//   标尺以下整片拖不进文件；
// - 文件落点垫在里面（ea746c1）：滤镜 / 音频库 / 转场三种卡片全被它吞掉；
// - 每条轨道行上挂着的转场落点（非主轨是空类型）：卡片拖到轨道行上的那一下
//   同样被吞。
//
// 只剩一个落点，这些嵌套规则就全都碰不上了。
// 案例：docs/bugfixes/2026-09-23-in-app-drops-swallowed-by-file-underlay.md

struct TimelineDropRouter: DropDelegate {
    let files: MediaFileDropDelegate
    let filter: FilterDropDelegate
    let audio: AudioLibraryDropDelegate
    let transition: TransitionDropDelegate
    /// 主轨那一行的纵向范围（内容坐标）。转场只落在主轨的接缝上；`nil` = 主轨
    /// 藏着，不接转场（同原来挂在行上时「藏起来的轨不认」那条）。
    let mainRow: ClosedRange<Double>?
    /// 内容区宽度。滤镜只许落在这以内：再往右是「填满视口」撑出来的空白，时间上
    /// 远超工程长度，而滤镜段不计入 `duration` —— 落到那儿就是一段谁也看不见、
    /// 也滚不到的调色（2026-09-21 口径，原来靠落点只挂到内容区为止来保证）。
    let contentWidth: Double

    /// 这个落点认的全部载荷。
    static let types: [UTType] = [
        FilterDrag.type, AudioLibraryDrag.type, TransitionDrag.type, .fileURL,
    ]

    private enum Payload {
        case filter, audio, transition, files
    }

    /// 这一次拖的是什么。**App 内的三种自定义载荷先认，文件最后认**：自定义载荷
    /// 只可能来自本 App 自己的 `.onDrag`，意图明确；反过来排的话，万一哪天卡片的
    /// provider 同时也给得出一个 file URL，它就会被当成从 Finder 拖进来的文件。
    private func payload(_ info: DropInfo) -> Payload? {
        if info.hasItemsConforming(to: [FilterDrag.type]) { return .filter }
        if info.hasItemsConforming(to: [AudioLibraryDrag.type]) { return .audio }
        if info.hasItemsConforming(to: [TransitionDrag.type]) { return .transition }
        if info.hasItemsConforming(to: [.fileURL]) { return .files }
        return nil
    }

    private func withinContent(_ info: DropInfo) -> Bool {
        info.location.x <= contentWidth
    }

    private func onMainRow(_ info: DropInfo) -> Bool {
        mainRow?.contains(info.location.y) ?? false
    }

    /// 这一轮拖放还活着吗。
    ///
    /// SwiftUI 在 `performDrop` **之后还会补发一拍** `dropUpdated`（2026-09-23 日志
    /// 实测：`validate → entered → updated… → PERFORM → updated`，没有 `exited`）。
    /// 这一拍照常转发的话：落点框按落地**之后**的状态重算一遍、挂在时间线上不走；
    /// 松手点正好在视口边缘时，自动滚动的心跳也被重新拉起来，时间线松手之后自己
    /// 一路滚到头。四套拖放都在松手时清掉自己起手记的那一笔，拿它判就够了。
    @MainActor
    private func isLive(_ payload: Payload) -> Bool {
        switch payload {
        case .files: MediaFileDrag.pending != nil
        case .filter: FilterDrag.preset != nil
        case .audio: AudioLibraryDrag.pending != nil
        case .transition: TransitionDrag.kind != nil
        }
    }

    func validateDrop(info: DropInfo) -> Bool {
        payload(info) != nil
    }

    func dropEntered(info: DropInfo) {
        switch payload(info) {
        case .files: files.dropEntered(info: info)
        case .audio: audio.dropEntered(info: info)
        case .filter where withinContent(info): filter.dropEntered(info: info)
        case .transition where onMainRow(info): transition.dropEntered(info: info)
        default: break
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard let payload = payload(info) else { return DropProposal(operation: .cancel) }
        // 松手之后补发的那一拍：什么都不做（理由见 `isLive`）。
        guard MainActor.assumeIsolated({ isLive(payload) }) else { return nil }
        switch payload {
        case .files:
            return files.dropUpdated(info: info)
        case .audio:
            return audio.dropUpdated(info: info)
        case .filter:
            guard withinContent(info) else {
                // 出了内容区：框收起来，指针变成禁止号。
                filter.dropExited(info: info)
                return DropProposal(operation: .cancel)
            }
            return filter.dropUpdated(info: info)
        case .transition:
            guard onMainRow(info) else {
                transition.dropExited(info: info)
                return DropProposal(operation: .cancel)
            }
            return transition.dropUpdated(info: info)
        }
    }

    func dropExited(info: DropInfo) {
        switch payload(info) {
        case .files: files.dropExited(info: info)
        case .audio: audio.dropExited(info: info)
        case .filter: filter.dropExited(info: info)
        case .transition: transition.dropExited(info: info)
        case nil: break
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        switch payload(info) {
        case .files:
            return files.performDrop(info: info)
        case .audio:
            return audio.performDrop(info: info)
        case .filter:
            guard withinContent(info) else {
                filter.dropExited(info: info)
                return false
            }
            return filter.performDrop(info: info)
        case .transition:
            guard onMainRow(info) else {
                transition.dropExited(info: info)
                return false
            }
            return transition.performDrop(info: info)
        case nil:
            return false
        }
    }
}
