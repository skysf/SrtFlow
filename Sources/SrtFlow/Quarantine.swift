import Foundation

/// 处理下载来源的隔离标记（`com.apple.quarantine`）。
///
/// 背景：SrtFlow 只做 ad-hoc 签名，没有 Developer ID 公证。DMG 经网页下载或
/// AirDrop 传到别人机器上后，整个 `.app` 会被打上隔离标记。用户在「右键 → 打开」
/// 里同意之后，App 本身能正常启动 —— **但包里嵌的可执行文件仍然会被系统直接
/// SIGKILL**（实测退出码 137，stderr 一个字都没有）。表现就是：软件能开，
/// 一点「开始压缩」或「烧制字幕」就失败，而且看不出原因。
///
/// 实测对整个 `.app` 执行 `xattr -dr com.apple.quarantine` 就能彻底解决。既然
/// 用户已经明确同意打开这个 App，那么由 App 自己清掉自身的隔离标记是合理的，
/// 也省得让每个朋友都去开一次终端。
enum Quarantine {

    private static let attributeName = "com.apple.quarantine"

    /// 这个路径上有没有隔离标记。
    static func isFlagged(atPath path: String) -> Bool {
        getxattr(path, attributeName, nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    @discardableResult
    static func removeFlag(atPath path: String) -> Bool {
        removexattr(path, attributeName, XATTR_NOFOLLOW) == 0
    }

    /// 递归清掉一棵目录树上的隔离标记。
    ///
    /// 只处理 `com.apple.quarantine`。`com.apple.provenance` 是系统保留的、
    /// 用户态删不掉，好在它并不影响执行。
    static func removeFlagRecursively(at url: URL) {
        let path = url.path
        removeFlag(atPath: path)

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let child as URL in enumerator {
            removeFlag(atPath: child.path)
        }
    }

    /// 自身 App 包此刻是不是还带着隔离标记。
    static var isOwnBundleFlagged: Bool {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else { return false }
        return isFlagged(atPath: bundleURL.path)
            || isFlagged(atPath: bundleURL.appendingPathComponent("Contents/Helpers/ffmpeg").path)
    }

    /// 给用户照着做的解隔离命令；没被隔离就返回 nil。
    static var fixCommandIfFlagged: String? {
        guard isOwnBundleFlagged else { return nil }
        return "xattr -dr com.apple.quarantine \"\(Bundle.main.bundleURL.path)\""
    }

    /// 如果自身 App 包被隔离了，就地修好，让包内的 ffmpeg 能正常执行。
    ///
    /// 返回是否真的做了修复，方便日志或界面提示。开发时（`swift run`）不在
    /// `.app` 里跑，这里什么都不会做。
    @discardableResult
    static func repairOwnBundleIfNeeded() -> Bool {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else { return false }

        // 先便宜地判断一下，绝大多数情况（本地构建、已修过）直接跳过。
        let helper = bundleURL.appendingPathComponent("Contents/Helpers/ffmpeg")
        let needsRepair = isFlagged(atPath: bundleURL.path)
            || (FileManager.default.fileExists(atPath: helper.path) && isFlagged(atPath: helper.path))
        guard needsRepair else { return false }

        removeFlagRecursively(at: bundleURL)
        return true
    }
}
