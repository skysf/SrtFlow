import Foundation
import SrtFlowMCPKit

// AI 接口（MCP）自检的公共小件：计数、断言、造片段。编法见 scripts/check-mcp.sh。

var failures = 0
var checks = 0

func check(_ condition: Bool, _ message: String, line: Int = #line) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL [\(#fileID):\(line)] \(message)")
    }
}

func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String, file: String = #fileID, line: Int = #line) {
    checks += 1
    if actual != expected {
        failures += 1
        print("FAIL [\(file):\(line)] \(message): got \(actual), expected \(expected)")
    }
}

/// 这段代码应该抛 `AIToolError`（或别的错）；没抛就记一条失败。
func checkThrows(_ message: String, line: Int = #line, _ body: () throws -> Void) {
    checks += 1
    do {
        try body()
        failures += 1
        print("FAIL [line \(line)] \(message): expected an error, got none")
    } catch {}
}

let media = URL(fileURLWithPath: "/tmp/srtflow-mcp-check/source.mp4")
let music = URL(fileURLWithPath: "/tmp/srtflow-mcp-check/music.m4a")

/// 一段视频：`duration` 秒，从 `start` 开始，素材本身 `asset` 秒长。
func videoClip(_ start: Double, _ duration: Double, asset: Double = 60, sourceStart: Double = 0) -> EditClip {
    var info = MediaInfo(
        duration: asset, displaySize: CGSize(width: 1920, height: 1080), frameRate: 30,
        videoCodec: "h264", audioCodec: "aac", hasAudio: true, audioCanCopyToMP4: true, fileBytes: 1
    )
    info.duration = asset
    return EditClip(sourceURL: media, sourceStart: sourceStart, sourceDuration: duration, timelineStart: start, info: info)
}

func audioClip(_ start: Double, _ duration: Double, asset: Double = 120) -> EditClip {
    EditClip(sourceURL: music, isAudioOnly: true, sourceDuration: duration, timelineStart: start, audioAssetDuration: asset)
}

func args(_ object: [String: JSONValue]) -> AIToolArguments {
    AIToolArguments(.object(object))
}

func mainStarts(_ state: TimelineState) -> [Double] {
    state.mainClips.map { ($0.timelineStart * 1000).rounded() / 1000 }
}
