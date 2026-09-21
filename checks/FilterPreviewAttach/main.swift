import AVFoundation
import AVKit
import AppKit
import CoreImage
import Foundation

// **预览调色真的挂上去了吗**：用生产的 `FilterStack` + `FilterStackAttachment`
// 把 LUT 挂到真的 AVPlayerView 上，拍窗口，数像素。
//
// 为什么非要真拍屏：`scripts/check-filters.sh` 守的是**表**（LUT 数学、和导出
// 逐像素对齐），它对「这张表有没有真的被挂到播放器上」一无所知。接线断了那边
// 照样全绿，而用户看到的是一点变化都没有的预览。
//
// 断言不比绝对色值 —— 截图会过一道显示色彩管理，绝对值对不上是正常的。比的是
// **次序**，那个不受色彩管理影响：
//
//   · 挂了滤镜的画面 ≠ 没挂的；
//   · 强度 60% 的每个通道都落在「原片」和「100%」之间；
//   · 播放头在滤镜段**之外**时，画面与原片一致；
//   · 只改强度走 keypath（生产里拖滑块那条便宜路）之后，画面**真的重绘**。
//
// 需要图形会话，所以**故意不在 check-all.sh 里**（无图形会话会假红），
// 同 scripts/check-instant-tooltip-panel.sh。跑法见 scripts/check-filter-preview-attach.sh。

var failures = 0
var checks = 0

func check(_ condition: Bool, _ message: String, line: Int = #line) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL [line \(line)] \(message)")
    }
}

let arguments = CommandLine.arguments
guard arguments.count >= 5 else {
    print("用法：<binary> <video> <out-fifo> <ctl-fifo> <shot-dir>")
    exit(2)
}
let videoURL = URL(fileURLWithPath: arguments[1])
let outFifo = arguments[2]
let ctlFifo = arguments[3]
let shotDirectory = URL(fileURLWithPath: arguments[4])

/// 一块面板：一个播放器 + 一份生产的挂载器。
/// `FilterStackAttachment` 是 @MainActor 的（生产里它只被 SwiftUI 的
/// `updateNSView` 调），面板跟着钉在主线程上。
@MainActor
final class Panel {
    let view = AVPlayerView()
    let attachment = FilterStackAttachment()
    let player: AVPlayer

    init(url: URL) {
        player = AVPlayer(url: url)
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspectFill
    }

    func apply(_ stack: FilterStack) {
        attachment.apply(stack, to: view)
    }
}

/// 截图里取一个点的 RGB（0…255）。
func pixel(_ image: CGImage, _ point: CGPoint) -> (Double, Double, Double)? {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    var raw = [UInt8](repeating: 0, count: 4)
    guard let context = CGContext(
        data: &raw, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.draw(
        image,
        in: CGRect(x: -point.x, y: -(Double(image.height) - point.y), width: Double(image.width), height: Double(image.height))
    )
    return (Double(raw[0]), Double(raw[1]), Double(raw[2]))
}

func loadShot(_ url: URL) -> CGImage? {
    guard let data = try? Data(contentsOf: url),
          let source = CGImageSourceCreateWithData(data as CFData, nil)
    else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

/// 每个通道都落在 a 和 b 之间（含容差）。次序断言不受截图色彩管理影响。
func between(
    _ value: (Double, Double, Double),
    _ a: (Double, Double, Double),
    _ b: (Double, Double, Double),
    tolerance: Double = 2
) -> Bool {
    func ok(_ v: Double, _ x: Double, _ y: Double) -> Bool {
        v >= min(x, y) - tolerance && v <= max(x, y) + tolerance
    }
    return ok(value.0, a.0, b.0) && ok(value.1, a.1, b.1) && ok(value.2, a.2, b.2)
}

func distance(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
    max(abs(a.0 - b.0), max(abs(a.1 - b.1), abs(a.2 - b.2)))
}

let panelWidth = 200.0
let panelHeight = 120.0
let gap = 10.0
let panelCount = 4

@MainActor
final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var panels: [Panel] = []

    /// 时间轴：0…2s 挂「冷铁 100%」，2…4s 挂「冷铁 60%」。四块面板分别取
    /// 播放头在 3 个不同时刻的栈，外加一块**完全不挂**的参照。
    func makeState() -> TimelineState {
        var state = TimelineState()
        state.filters = [
            FilterClip(preset: .coldIron, strength: 1, timelineStart: 0, duration: 2, layer: 0),
            FilterClip(preset: .coldIron, strength: 0.6, timelineStart: 2, duration: 2, layer: 0),
        ]
        return state
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let width = panelWidth * Double(panelCount) + gap * Double(panelCount + 1)
        let height = panelHeight + gap * 2
        window = NSWindow(
            contentRect: NSRect(x: 60, y: 60, width: width, height: height),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.title = "FilterPreviewAttach"
        window.backgroundColor = .black
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        root.wantsLayer = true
        window.contentView = root

        let state = makeState()
        // 面板 0：参照（空栈）；1：t=1（冷铁 100%）；2：t=3（冷铁 60%）；3：t=9（区间外）。
        let stacks = [
            FilterStack.empty,
            FilterStack(in: state, at: 1),
            FilterStack(in: state, at: 3),
            FilterStack(in: state, at: 9),
        ]
        for index in 0..<panelCount {
            let panel = Panel(url: videoURL)
            panel.view.frame = NSRect(
                x: gap + (panelWidth + gap) * Double(index), y: gap,
                width: panelWidth, height: panelHeight
            )
            root.addSubview(panel.view)
            panel.apply(stacks[index])
            panels.append(panel)
        }

        check(stacks[1].entries.count == 1, "t=1 落在第一段滤镜里")
        check(stacks[2].entries.first?.strength == 0.6, "t=3 拿到的是 60% 那一段")
        check(stacks[3].isEmpty, "t=9 在所有滤镜段之外，栈是空的")

        window.orderFrontRegardless()
        panels.forEach { $0.player.play() }

        Task { await self.drive() }
    }

    /// 和外面的脚本换手：写窗口号 → 等它拍完 → 继续。
    func handshake() async {
        let id = window.windowNumber
        // 写 FIFO 和等回执都是**阻塞**的，不能占着主线程 —— 占了的话窗口
        // 停止刷新，截出来的是一张白板。
        await Task.detached {
            try? "\(id)\n".write(toFile: outFifo, atomically: false, encoding: .utf8)
            _ = FileHandle(forReadingAtPath: ctlFifo)?.readLine()
        }.value
    }

    func drive() async {
        // 画面稳定之后再拍。
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await handshake()

        // 第二拍：只改强度，走生产里那条 keypath 便宜路（拖滑块就是它）。
        // 面板 2 从 60% 拉到 100%，画面必须跟着变。
        var bumped = TimelineState()
        bumped.filters = [
            FilterClip(preset: .coldIron, strength: 1, timelineStart: 0, duration: 4, layer: 0)
        ]
        panels[2].apply(FilterStack(in: bumped, at: 1))
        try? await Task.sleep(nanoseconds: 600_000_000)
        await handshake()

        report()
    }

    func report() {
        guard let first = loadShot(shotDirectory.appendingPathComponent("shot1.png")),
              let second = loadShot(shotDirectory.appendingPathComponent("shot2.png")) else {
            check(false, "截图读不出来（图形会话不在？）")
            finish()
            return
        }
        let scale = Double(first.width) / window.frame.width
        func center(_ index: Int) -> CGPoint {
            CGPoint(
                x: (gap + (panelWidth + gap) * Double(index) + panelWidth / 2) * scale,
                y: (gap + panelHeight / 2) * scale
            )
        }
        guard let reference = pixel(first, center(0)),
              let full = pixel(first, center(1)),
              let partial = pixel(first, center(2)),
              let outside = pixel(first, center(3)) else {
            check(false, "取像素失败")
            finish()
            return
        }

        check(distance(full, reference) > 6, "挂了滤镜的画面和原片明显不同（真的挂上去了）")
        check(distance(outside, reference) <= 2, "滤镜段之外的画面就是原片")
        check(between(partial, reference, full), "60% 的每个通道都落在原片与 100% 之间")
        check(distance(partial, reference) > 3, "60% 和原片看得出差别")
        check(distance(partial, full) > 3, "60% 和 100% 看得出差别")

        guard let bumped = pixel(second, center(2)) else {
            check(false, "第二张截图取像素失败")
            finish()
            return
        }
        check(distance(bumped, partial) > 3, "只改强度（keypath）之后画面真的重绘了")
        check(distance(bumped, full) <= 2, "改到 100% 之后和满强度那块一致")

        finish()
    }

    func finish() -> Never {
        print("\(checks) checks, \(failures) failures")
        if failures == 0 { print("All checks passed") }
        exit(failures == 0 ? 0 : 1)
    }
}

extension FileHandle {
    /// 阻塞读一行（换手用）。
    func readLine() -> String? {
        var bytes = Data()
        while let chunk = try? read(upToCount: 1), !chunk.isEmpty {
            if chunk.first == 0x0A { break }
            bytes.append(chunk)
        }
        return String(data: bytes, encoding: .utf8)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = MainActor.assumeIsolated { Delegate() }
app.delegate = delegate
app.run()
