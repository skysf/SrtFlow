import Foundation
import os
import Security

/// 录屏授权的自修复：「系统设置里 SrtFlow 的开关开着，录自定义区域还是说没权限」。
///
/// 为什么会这样：macOS 的隐私授权（TCC）每条记录都钉着当时那个签名的 designated requirement。ad-hoc 签名的
/// requirement 就是 cdhash，换一个构建（升级、重编）就对不上，系统按「没授权」处理；而在系统设置里把开关关掉再
/// 打开只改开关、**不换钉着的签名**（2026-10-03 在 macOS 26.5 上从 TCC.db 读出来的），怎么拨都没用。出路只有把这条
/// 记录删掉、让系统重新问一次：`tccutil reset ScreenCapture <bundle id>`。
///
/// 发布版改用固定的签名证书（`scripts/signing/sign-app.sh`）之后，升级不再让记录作废；这里兜的是改签之前留下的
/// 旧记录，和没有那把证书的构建（自己编的、开发版）。见 docs/architecture/code-signing-and-permissions.md。
///
/// 管什么：这一个构建删过没有、删。不管什么：请求授权、给用户的话（`ScreenRecordingPermissions`、
/// `ScreenRecordingError.localizedText`）。
enum ScreenCapturePermissionRepair {
    /// 删过的那个构建的 cdhash。
    private static let resetBuildKey = "screenRecording.permissionResetForBuild"
    private static let log = Logger(subsystem: "com.srtflow.SrtFlow", category: "screen-capture-permission")

    /// 这一个构建还没删过的话，删掉 SrtFlow 自己那条录屏授权记录。只在「没授权」时调。
    ///
    /// **每个构建最多删一次**：删完、系统重新问过一次之后，同一个构建再被拒，要么是用户没开，要么是开了还没
    /// 重开 SrtFlow（授权下次启动才生效）—— 再删只会把用户刚开的那条也删掉。
    /// - Returns: 真的删了。
    @discardableResult
    static func resetRecordOncePerBuild(defaults: UserDefaults = .standard) async -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier, let build = runningBuildHash() else { return false }
        guard defaults.string(forKey: resetBuildKey) != build else { return false }
        let status = await ChildProcess.exitStatus(
            URL(fileURLWithPath: "/usr/bin/tccutil"), ["reset", "ScreenCapture", bundleID]
        )
        guard status == 0 else {
            log.error("tccutil reset ScreenCapture \(bundleID, privacy: .public) exited \(status)")
            return false
        }
        defaults.set(build, forKey: resetBuildKey)
        return true
    }

    /// 正在跑的这个构建的 cdhash（十六进制）。读不到签名返回 nil。
    static func runningBuildHash() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
                staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information
              ) == errSecSuccess,
              let unique = (information as? [String: Any])?[kSecCodeInfoUnique as String] as? Data
        else { return nil }
        return unique.map { String(format: "%02x", $0) }.joined()
    }
}
