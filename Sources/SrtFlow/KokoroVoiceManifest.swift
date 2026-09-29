import CryptoKit
import Foundation

// MARK: - 本机配音模型的清单（纯值）
//
// 管什么：R2 上那份 manifest.json 长什么样（每个文件的相对路径、大小、SHA-256）、读进来先验一遍（路径不许跳出模型目录、
// 校验值得是 64 位十六进制），以及算一个文件的 SHA-256（边读边算，三百多 MB 的权重也不整个读进内存）。
// 清单由 scripts/voice-models/upload.py 生成（方案第 51 条：传到我们自己的 R2，下完核校验值）。
// 不管什么：下载和安装（KokoroVoicePack）。

struct KokoroVoiceManifest: Codable, Equatable {
    struct File: Codable, Equatable {
        /// 相对模型目录的路径（如 `kokoro_5s.mlmodelc/weights/weight.bin`）。
        var path: String
        var size: Int64
        var sha256: String
    }

    var name: String
    var version: Int
    var files: [File]

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    /// 读 JSON 并验一遍。清单是远程数据：一个写着 `../../` 的路径会让下载把文件写到模型目录外面去。
    static func decode(_ data: Data) throws -> KokoroVoiceManifest {
        let manifest = try JSONDecoder().decode(KokoroVoiceManifest.self, from: data)
        guard !manifest.files.isEmpty else { throw AIToolError("The voice model's file list is empty.") }
        for file in manifest.files {
            guard isSafe(file.path) else { throw AIToolError("The voice model's file list has a bad path: \(file.path)") }
            guard file.size >= 0, file.sha256.count == 64,
                  file.sha256.allSatisfy({ $0.isHexDigit }) else {
                throw AIToolError("The voice model's file list has a bad entry: \(file.path)")
            }
        }
        return manifest
    }

    /// 只许是模型目录里面的相对路径：不空、不以 / 开头、没有 `..` 和 `.` 这一段、没有反斜杠。
    static func isSafe(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != ".." && $0 != "." }
    }

    /// 一个文件的 SHA-256（小写十六进制），1 MB 一块地读。
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
