import AppKit
import Foundation
import ScreenCaptureKit
import SrtFlowCore

/// 系统来源 picker（`SCContentSharingPicker`）的 adapter。
///
/// 职责边界（计划 §4.2）：只负责「让用户选一个来源」并把结果翻译成
/// `ScreenRecordingSource` + 可用的 `SCContentFilter`。**不做**权限请求、
/// 不建 writer、不碰工程。
///
/// 三条来源的分工（计划 §20 + Phase 0 门槛 9）：
/// - **单窗口**：直接用 picker 返回的 filter，**不为排除控制窗重建** ——
///   picker 给的 filter 本来就只含那个窗口，控制窗不在里面。
/// - **整屏**：picker 只用来让用户挑显示器；真正的 filter 由 coordinator 在
///   建好 Stop 窗、拿到它的 windowID 之后用
///   `SCContentFilter(display:excludingWindows:)` 重建（实测有效：
///   排除前采样点是洋红、排除后是灰）。
/// - **自定义区域**：不走 picker，走 `ScreenRecordingRegionPanel`。
@available(macOS 15.0, *)
@MainActor
final class ScreenRecordingSourcePicker: NSObject {

    enum PickerError: Error, LocalizedError {
        /// 用户取消。**这不是权限问题**，不许当权限拒绝报（计划 §17.1-1）。
        case cancelled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled: return L10n("Source selection was cancelled.")
            case .failed(let message): return message
            }
        }
    }

    struct Selection {
        var source: ScreenRecordingSource
        /// picker 直接给的 filter。单窗口来源直接用它；
        /// 整屏来源会被 coordinator 用「排除控制窗」的版本替换。
        var filter: SCContentFilter
    }

    /// picker 允许的模式。区域走自己的 overlay，不在这里。
    enum Mode {
        case display
        case window

        var pickerModes: SCContentSharingPickerMode {
            switch self {
            case .display: return [.singleDisplay]
            case .window: return [.singleWindow]
            }
        }
    }

    private var continuation: CheckedContinuation<Selection, Error>?
    private var mode: Mode = .display
    /// 已登记为 observer —— `SCContentSharingPicker` 是**进程级单例**，
    /// 重复 add/remove 会让回调错乱，所以只登记一次。
    private var isObserving = false

    /// 呈现 picker 并等待用户选择。
    ///
    /// - Parameter excludedWindowIDs: 录制控制窗等不该出现在候选里的窗口。
    func present(mode: Mode, excludedWindowIDs: [CGWindowID] = []) async throws -> Selection {
        // 同一时刻只允许一个等待者：重复点入口只激活现有会话（计划 §11.1）。
        if continuation != nil { throw PickerError.failed(L10n("A source picker is already open.")) }
        self.mode = mode

        let picker = SCContentSharingPicker.shared
        if !isObserving {
            picker.add(self)
            isObserving = true
        }
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = mode.pickerModes
        // 注意类型：这个属性是 [Int] 而不是 [CGWindowID]（后者是 UInt32），
        // 必须显式转换 —— 文档页名字容易让人写成 CGWindowID。
        configuration.excludedWindowIDs = excludedWindowIDs.map(Int.init)
        // SDK header 里这个属性默认是 YES。留着默认值的话，用户可以在录制期间
        // 从 picker 里换掉来源，而我们已经按开录那一刻的来源冻结了捕获像素
        // 尺寸和 sourceRect —— 换了就对不上（复审二 P2）。
        configuration.allowsChangingSelectedContent = false
        picker.defaultConfiguration = configuration
        picker.isActive = true

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            picker.present()
        }
    }

    /// 会话结束后收摊。picker 是进程级单例，长期挂 observer 会影响别处。
    func invalidate() {
        if isObserving {
            SCContentSharingPicker.shared.remove(self)
            isObserving = false
        }
        SCContentSharingPicker.shared.isActive = false
        finish(.failure(PickerError.cancelled))
    }

    private func finish(_ result: Result<Selection, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        SCContentSharingPicker.shared.isActive = false
        continuation.resume(with: result)
    }

    /// 从 filter 反推来源。picker 不直接给「用户选了哪块屏/哪个窗口」，
    /// 只给 filter，所以要按 filter 的 style 判读。
    ///
    /// **解析只能发生在 picker 回调之后。** 早先在 `present()` 之前就调
    /// `SCShareableContent` 预热缓存，clean TCC 下那一步必然失败并留下空缓存，
    /// 于是用户在 picker 里选好了窗口，回调却反推不出来源 —— 首次运行直接废掉
    /// （复审 P1-5）。走到这里时用户已经在 picker 里授过权，读取是安全的。
    private func resolveSource(from filter: SCContentFilter) async throws -> ScreenRecordingSource {
        switch filter.style {
        case .display:
            // 15.2 起 filter 直接给出选中的显示器，不用猜。
            if #available(macOS 15.2, *), let display = filter.includedDisplays.first {
                return .display(displayID: display.displayID)
            }
            await refreshShareableContent()
            let rect = filter.contentRect
            let matches = cachedDisplays.filter {
                abs($0.frame.width - rect.width) < 1 && abs($0.frame.height - rect.height) < 1
            }
            return .display(displayID: try unique(matches).displayID)
        case .window:
            if #available(macOS 15.2, *), let window = filter.includedWindows.first {
                return .window(windowID: window.windowID)
            }
            await refreshShareableContent()
            let rect = filter.contentRect
            let matches = cachedWindows.filter {
                abs($0.frame.width - rect.width) < 2 && abs($0.frame.height - rect.height) < 2
            }
            return .window(windowID: try unique(matches).windowID)
        default:
            throw ScreenRecordingError.sourceUnavailable
        }
    }

    /// 几何匹配必须**唯一**才算数。
    ///
    /// 两块同尺寸显示器（或两个同尺寸窗口）时，早先的 `first` 会闷头取第一个，
    /// 用户选了右屏却录了左屏，而且录完才发现（复审 P1-5）。宁可报错。
    private func unique<T>(_ matches: [T]) throws -> T {
        guard let first = matches.first else { throw ScreenRecordingError.sourceUnavailable }
        guard matches.count == 1 else { throw ScreenRecordingError.ambiguousSource }
        return first
    }

    private var cachedDisplays: [SCDisplay] = []
    private var cachedWindows: [SCWindow] = []

    /// 读取当前可分享内容。**只在 picker 回调之后调用**（见 `resolveSource`）。
    private func refreshShareableContent() async {
        let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        cachedDisplays = content?.displays ?? []
        cachedWindows = content?.windows ?? []
    }
}

@available(macOS 15.0, *)
extension ScreenRecordingSourcePicker: SCContentSharingPickerObserver {

    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        Task { @MainActor in
            do {
                let source = try await self.resolveSource(from: filter)
                self.finish(.success(Selection(source: source, filter: filter)))
            } catch {
                self.finish(.failure(error))
            }
        }
    }

    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker, didCancelFor stream: SCStream?
    ) {
        // 取消不是错误，更不是权限拒绝。
        Task { @MainActor in self.finish(.failure(PickerError.cancelled)) }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in
            self.finish(.failure(PickerError.failed(error.localizedDescription)))
        }
    }
}
