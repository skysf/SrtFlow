import Foundation

// MARK: - 进程内冒烟脚本的步骤表
//
// 管什么：`SRTFLOW_SMOKE_SCRIPT` 指向的那份 JSON 长什么样、怎么读。
// 不管什么：执行（`SmokeDriver`）。
//
// 一份脚本就是一个数组，每一项是一步，`do` 说做什么：
//
//   {"do": "wait", "seconds": 1}                     干等
//   {"do": "settle", "quiet": 0.6, "timeout": 30}    等预览落定（同性能测试的口径）
//   {"do": "window", "width": 1400, "height": 860}   把窗口摆成这么大（左下角贴着屏幕可用区域）
//   {"do": "seek", "time": 3.5}                      播放头挪过去
//   {"do": "click", "at": [x, y], "count": 1, "flags": ["cmd"]}
//   {"do": "drag", "from": [x, y], "to": [x, y], "steps": 20, "hold": 0.3, "flags": []}
//   {"do": "scroll", "at": [x, y], "dx": 0, "dy": -40, "steps": 10}
//   {"do": "key", "code": 0, "chars": "a", "flags": ["cmd"]}
//   {"do": "hit", "at": [x, y]}                      日志里记下这一点命中的是哪个 NSView（排查用）
//   {"do": "perfReset"} / {"do": "perf", "label": "拖动"}   计数清零 / 记一份快照
//   {"do": "state", "label": "拖完"}                 记下工程此刻的样子（选择、各段位置）
//   {"do": "snapshot", "name": "after-drag"}         请外面拍一张窗口截图（见 SmokeDriver）
//   {"do": "quit"}
//
// 坐标一律是**窗口的点、左上原点**（按窗口 ID 截的图除以 2 就是）。

struct SmokeStep: Decodable {
    enum Action: String, Decodable {
        case wait, settle, window, seek, click, drag, scroll, key, hit
        case perfReset, perf, state, snapshot, quit
    }

    var action: Action
    var seconds: Double?
    var quiet: Double?
    var timeout: Double?
    var width: Double?
    var height: Double?
    var time: Double?
    var at: [Double]?
    var from: [Double]?
    var to: [Double]?
    var count: Int?
    var steps: Int?
    var hold: Double?
    var dx: Double?
    var dy: Double?
    var code: UInt16?
    var chars: String?
    var flags: [String]?
    var label: String?
    var name: String?

    private enum CodingKeys: String, CodingKey {
        case action = "do"
        case seconds, quiet, timeout, width, height, time, at, from, to, count, steps, hold
        case dx, dy, code, chars, flags, label, name
    }

    static func load(from url: URL) throws -> [SmokeStep] {
        try JSONDecoder().decode([SmokeStep].self, from: Data(contentsOf: url))
    }

    /// `[x, y]` → 点。缺了或者不是两个数就是脚本写错了。
    static func point(_ pair: [Double]?, _ what: String) throws -> CGPoint {
        guard let pair, pair.count == 2 else { throw SmokeScriptError("\(what) 要写成 [x, y]") }
        return CGPoint(x: pair[0], y: pair[1])
    }
}

struct SmokeScriptError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
