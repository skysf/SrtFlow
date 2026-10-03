import Foundation
import ScreenCaptureKit
import SrtFlowCore

// MARK: - 录制设置项：设置页（或 record_screen）→ 协调者的输入
//
// 管什么：录什么（来源种类、区域比例，或者 AI 已经挑好的来源）、录不录声音和麦克风、指针、存到哪。
// 不管什么：这一次是谁起的、要不要问人（`ScreenRecordingSession`）；怎么选来源（`ScreenRecordingCoordinator.chooseSource`）。
// 2026-10-03 从 ScreenRecordingCoordinator+Setup.swift 搬出来（那个文件超过 600 行，只许降）。

struct ScreenRecordingOptions {
    enum SourceKind: String, CaseIterable, Identifiable {
        case display, window, region
        var id: String { rawValue }
        var title: String {
            switch self {
            case .display: return "Entire display"
            case .window: return "A window"
            case .region: return "Custom region"
            }
        }
    }

    var sourceKind: SourceKind = .display
    var regionRatio: RegionAspectRatio = .free
    /// AI 已经挑好的来源（record_screen）：有它就**不开系统的选择窗口、不弹区域框**，直接用。
    /// 手动录永远是 nil（来源由系统的选择窗口或用户拖的区域给）。
    var preset: ScreenRecordingPresetSource?
    var capturesSystemAudio = true
    var microphone: MicrophoneConfiguration = .disabled
    var cursor: CursorConfiguration = .default
    /// 用户在设置页里选好的保存位置（AI 起的：`<起点>/SrtFlow/录屏/` 下撞名加了编号的那个）。
    ///
    /// 保存位置**在设置页里就定下来**，不放到系统 picker 之后再问：
    /// 那个顺序是「先被系统 picker 的 Cancel / Share Entire Screen 问一次，
    /// 再被保存面板问一次」，用户不知道自己走到哪一步了（真机首测反馈）。
    var outputURL: URL?
}

/// AI 已经挑好的来源。
///
/// - 整块屏幕 / 窗口：filter 是 `SCShareableContent` 现取的（要广域的屏幕录制授权，AI 起之前查过），
///   和系统选择窗口给的 filter 一样直接用（`finalFilter` 不重建，控制浮窗靠 `sharingType = .none` 摘出去）。
/// - 区域：filter 为 nil，开录前按显示器重建 —— 和手动拖的区域走同一条路。
@available(macOS 15.0, *)
struct ScreenRecordingPresetSource {
    var source: ScreenRecordingSource
    var filter: SCContentFilter?
}
