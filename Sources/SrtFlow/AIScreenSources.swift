import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - 这台 Mac 上能录什么：屏幕、窗口、麦克风
//
// 管什么：读候选（显示器、系统的窗口表、麦克风）、给 get_status 列出来、把 AI 挑好的来源变成协调者要的 preset
// （整屏 / 窗口现取 `SCShareableContent` 的 filter）。挑的规则在 AIScreenSourceMatch（纯值）。
// 不管什么：授权（ScreenRecordingPermissions）、开录（AIScreenRecordingTool）。
//
// 列窗口用 `CGWindowListCopyWindowInfo`（从前到后）：只读一张表、不碰捕获。窗口标题要「屏幕与系统音频录制」授权
// 才读得到，没授权时只有 App 名。真要录的那一刻才问 `SCShareableContent` 要那个窗口 / 显示器（同一个编号）。

@available(macOS 15.0, *)
@MainActor
enum AIScreenSources {
    static func displays() -> [AIScreenSourceMatch.Display] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = number.uint32Value
            // 真实像素只有 CGDisplayMode.pixelWidth 给（CGDisplayPixelsWide 返回的是点，录屏实施报告门槛 10）。
            let mode = CGDisplayCopyDisplayMode(id)
            return AIScreenSourceMatch.Display(
                id: id, name: screen.localizedName, frame: CGDisplayBounds(id),
                pixelSize: CGSize(width: mode?.pixelWidth ?? 0, height: mode?.pixelHeight ?? 0),
                isMain: CGDisplayIsMain(id) != 0
            )
        }
    }

    /// 屏幕上的窗口，从前到后。
    static func windows() -> [AIScreenSourceMatch.Window] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo as CFDictionary) else { return nil }
            let sharing = (info[kCGWindowSharingState as String] as? NSNumber)?.uint32Value ?? CGWindowSharingType.readOnly.rawValue
            return AIScreenSourceMatch.Window(
                id: id,
                app: info[kCGWindowOwnerName as String] as? String ?? "",
                title: info[kCGWindowName as String] as? String ?? "",
                frame: bounds,
                layer: (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                shareable: sharing != CGWindowSharingType.none.rawValue
            )
        }
    }

    static func microphones() -> [AIScreenSourceMatch.Microphone] {
        ScreenRecordingPermissions.microphoneDevices().map { AIScreenSourceMatch.Microphone(id: $0.id, name: $0.name) }
    }

    // MARK: get_status

    /// get_status 的 screen_recording 一节：状态、授权、在跑的任务、上次没收完的；`listSources` 时再列屏幕 / 窗口 / 麦克风
    /// （窗口标题可能带隐私，平时不列，docs/plans/2026-10-03-screen-recording-mcp.md 第 13 条）。
    static func statusJSON(listSources: Bool) -> JSONValue {
        let coordinator = ScreenRecordingCoordinator.shared
        var object: [String: JSONValue] = [
            "state": .string(AIScreenRecordingWords.state(coordinator.state)),
            "permission": .string(ScreenRecordingPermissions.screen == .authorized ? "granted" : "not_granted")
        ]
        if case .recording(let startedAt) = coordinator.state {
            object["recorded_seconds"] = .number(Date().timeIntervalSince(startedAt).rounded())
        }
        if let job = AIScreenRecordingTool.current?.job, job.status == .running { object["job_id"] = .string(job.id) }
        if let leftover = AIScreenRecordingLeftovers.json(coordinator) { object["leftover"] = leftover }
        guard listSources else { return .object(object) }

        object["displays"] = .array(AIScreenSourceMatch.numbered(displays()).enumerated().map { index, display in
            [
                "display": .number(Double(index + 1)), "name": .string(display.name), "main": .bool(display.isMain),
                "size": .string("\(Int(display.frame.width))×\(Int(display.frame.height))"),
                "pixels": .string("\(Int(display.pixelSize.width))×\(Int(display.pixelSize.height))")
            ]
        })
        object["windows"] = .array(AIScreenSourceMatch.recordable(windows()).prefix(40).map { window in
            var entry: [String: JSONValue] = [
                "window": .string(String(window.id)), "app": .string(window.app),
                "size": .string("\(Int(window.frame.width))×\(Int(window.frame.height))")
            ]
            if !window.title.isEmpty { entry["title"] = .string(window.title) }
            return .object(entry)
        })
        let defaultID = ScreenRecordingPermissions.defaultMicrophoneID
        object["microphones"] = .array(microphones().map { ["name": .string($0.name), "default": .bool($0.id == defaultID)] })
        object["microphone_permission"] = .string(microphonePermissionWord())
        return .object(object)
    }

    private static func microphonePermissionWord() -> String {
        switch ScreenRecordingPermissions.microphone {
        case .authorized: return "granted"
        case .notDetermined: return "not_asked (macOS asks the user the first time record_screen uses a microphone)"
        default: return "denied (System Settings ▸ Privacy & Security ▸ Microphone)"
        }
    }

    // MARK: 开录

    /// AI 挑好的来源 → 协调者要的 preset，外加一句给 AI 看的「录的是什么」。
    /// 整屏 / 窗口现取 `SCShareableContent`（要授权，调用方先查过）；区域只要显示器几何（filter 开录前照手动的区域重建）；
    /// drag 没有 preset（区域框让用户拖）。
    static func preset(
        for source: AIScreenRecordingRequest.Source
    ) async throws -> (preset: ScreenRecordingPresetSource?, description: String) {
        switch source {
        case .display(let number):
            let display = try AIScreenSourceMatch.pickDisplay(number, among: displays())
            let content = try await shareableContent()
            guard let captured = content.displays.first(where: { $0.displayID == display.id }) else {
                throw AIToolError("Display \(number ?? 1) is gone; get_status screen=true lists the current ones.")
            }
            return (
                ScreenRecordingPresetSource(source: .display(displayID: display.id), filter: SCContentFilter(display: captured, excludingWindows: [])),
                "display \(number ?? 1) (\(display.name))"
            )
        case .window(let query):
            let window = try AIScreenSourceMatch.pickWindow(query, among: windows())
            let content = try await shareableContent()
            guard let captured = content.windows.first(where: { $0.windowID == window.id }) else {
                throw AIToolError("The \(window.app) window closed before recording could start.")
            }
            let title = window.title.isEmpty ? "" : " — \(window.title)"
            return (
                ScreenRecordingPresetSource(source: .window(windowID: window.id), filter: SCContentFilter(desktopIndependentWindow: captured)),
                "window \(window.id): \(window.app)\(title)"
            )
        case .region(let number, let fractions):
            let display = try AIScreenSourceMatch.pickDisplay(number, among: displays())
            let rect = try AIScreenSourceMatch.localRect(fractions: fractions, display: display)
            return (
                ScreenRecordingPresetSource(source: .region(displayID: display.id, rectInPoints: rect), filter: nil),
                "an area of display \(number ?? 1), \(Int(rect.width))×\(Int(rect.height)) points"
            )
        case .drag:
            return (nil, "an area the user drags")
        }
    }

    /// 授权查过了还失败：多半是 macOS 正弹着它自己的录屏提醒（约每 30 天一次，SrtFlow 关不掉），或者别的系统原因。
    private static func shareableContent() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw AIToolError(
                "macOS refused screen capture just now (\(error.localizedDescription)). If it is showing a screen recording prompt or "
                    + "reminder, ask the user to allow SrtFlow, then call record_screen again."
            )
        }
    }
}
