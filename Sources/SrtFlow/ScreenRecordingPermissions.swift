import AVFoundation
import CoreGraphics
import Foundation
import SrtFlowCore

/// 屏幕录制 / 麦克风权限的唯一查询口。
///
/// Phase 0 实测结论（`docs/reports/2026-08-06-native-screen-recording-implementation-report.md`
/// 门槛 1），产品必须照此实现：
///
/// 1. **`SCShareableContent` 不会拉起授权弹窗，只会直接抛 -3801。**
///    不能指望它来请求权限。
/// 2. **-3801 的文案是「user declined」，但它同样覆盖「从未授权」。**
///    界面文案只能写「未获授权」，**不许**写「你拒绝过」。
/// 3. **`CGRequestScreenCaptureAccess()` 的同步返回值不可信**（弹窗是异步的，
///    授权在下次启动才生效）；`CGPreflightScreenCaptureAccess()` 只查状态、
///    不弹窗，可以安全地用于 UI 判定。
/// 4. ad-hoc 签名的 App 反复重签会让 TCC 记录失配，出现「设置里开关是开的但
///    仍被拒」的死状态 —— SrtFlow 正式包正是 ad-hoc 签名，所以引导文案里
///    必须给出「关掉再打开」这条恢复路径（实测这才是生效的那条）。
@available(macOS 15.0, *)
enum ScreenRecordingPermissions {

    enum ScreenStatus: Equatable {
        case authorized
        /// 未获授权。**注意不是「用户拒绝过」** —— 见类型注释第 2 条。
        case notAuthorized
    }

    /// 只查状态，绝不弹窗。UI 判定用它。
    static var screen: ScreenStatus {
        CGPreflightScreenCaptureAccess() ? .authorized : .notAuthorized
    }

    /// 请求屏幕录制授权。
    ///
    /// 返回值**只表示「此刻是否已授权」**，不表示用户刚才怎么选 ——
    /// 弹窗是异步的，用户点了允许也要下次启动才生效（Phase 0 实测）。
    /// 调用方据此提示「授权后请重新打开 SrtFlow」，不要假装已经生效。
    @discardableResult
    static func requestScreenAccess() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        _ = CGRequestScreenCaptureAccess()
        return CGPreflightScreenCaptureAccess()
    }

    /// 打开「系统设置 → 隐私与安全性 → 屏幕与系统音频录制」。
    static var screenSettingsURL: URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
    }

    static var microphoneSettingsURL: URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
    }

    // MARK: 麦克风

    static var microphone: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// 只在用户真的开启麦克风时才调用 —— 关闭时不许触发麦克风提示（计划 §11.2-3）。
    static func requestMicrophoneAccess() async -> Bool {
        switch microphone {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// 可用的麦克风设备。`captureMicrophone` 必须传**已解析**的 uniqueID
    /// （Phase 0 门槛 2），所以这里返回的是解析过的设备表。
    static func microphoneDevices() -> [(id: String, name: String)] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone], mediaType: .audio, position: .unspecified
        ).devices.map { ($0.uniqueID, $0.localizedName) }
    }

    /// 系统默认输入设备的 uniqueID；没有任何输入设备时为 nil。
    static var defaultMicrophoneID: String? {
        AVCaptureDevice.default(for: .audio)?.uniqueID
    }
}

/// 录屏的普通偏好（**不是**契约状态，用 UserDefaults 正合适 —— 计划 §7.3）。
///
/// 与 manifest 的区别：这些丢了只是少一点便利，manifest 丢了会丢文件。
enum ScreenRecordingPreferences {
    private static let microphoneEnabledKey = "screenRecording.microphoneEnabled"
    private static let microphoneDeviceKey = "screenRecording.microphoneDeviceID"
    private static let lastDirectoryKey = "screenRecording.lastDirectory"

    static var microphoneEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: microphoneEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: microphoneEnabledKey) }
    }

    static var microphoneDeviceID: String? {
        get { UserDefaults.standard.string(forKey: microphoneDeviceKey) }
        set { UserDefaults.standard.set(newValue, forKey: microphoneDeviceKey) }
    }

    /// 保存目录：**上次用过的**，没有就回落到「下载」。
    ///
    /// 只在**录制真的开始之后**才记，避免把取消也记进去。
    /// 记住的目录若已经不在了（外置盘拔了、文件夹删了），同样回落到「下载」——
    /// 绝不返回一个不存在的路径。
    static var lastDirectory: URL {
        get {
            if let path = UserDefaults.standard.string(forKey: lastDirectoryKey) {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                   isDirectory.boolValue {
                    return URL(fileURLWithPath: path, isDirectory: true)
                }
            }
            return defaultDirectory
        }
        set { UserDefaults.standard.set(newValue.path, forKey: lastDirectoryKey) }
    }

    /// 默认落点：「下载」。取不到就用家目录兜底。
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }
}

/// `MediaProbe.probe` 的窄封装：录屏这边只关心「探到了就用，没探到就算了」。
@available(macOS 15.0, *)
@MainActor
enum ScreenRecordingProbe {
    static func info(_ url: URL) async -> MediaInfo? {
        let result = await MediaProbe.probe(url: url, ffmpeg: MediaToolchain.shared.runtime?.url)
        if case .success(let info) = result { return info }
        return nil
    }

    /// 纯音频文件的时长。
    ///
    /// **麦克风 sidecar 不能走 `info(_:)`** —— 它底下是 `MediaProbe`，而
    /// `MediaProbe` 无视频轨就抛 `noVideoTrack`（`MediaProbe.swift` 的
    /// `probeWithAVFoundation`）。用它探 `.m4a` 永远返回 nil，麦克风轨就
    /// **永远进不了时间线**（复审二 P1-1）。这里按音频轨自己判。
    ///
    /// - Returns: 有可用音频轨且时长 > 0 时返回时长，否则 nil。
    static func audioDuration(_ url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio),
              !tracks.isEmpty,
              let duration = try? await asset.load(.duration).seconds,
              duration.isFinite, duration > 0 else { return nil }
        return duration
    }
}
