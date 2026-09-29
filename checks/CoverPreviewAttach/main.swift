import AVFoundation
import AVKit
import AppKit
import CoreImage
import Foundation

// **预览上的盖一块真的盖上了吗**：用生产的 `CoverHostView`（同一个播放器再开一层）+ `CoverStack` + `FilterStackAttachment`
// 放进真的窗口，拍屏，数像素。
//
// 为什么非要真拍屏：`scripts/check-cover-export.sh` 守的是成片；预览这一层是 CALayer + 图层滤镜，纯值的自检对「这一层有没有真的
// 挂上、盖在哪、蒙没蒙对」一无所知 —— 接线断了那边照样全绿，用户看到的是一点变化都没有的预览。
// 断言不比绝对色值（截图会过一道显示色彩管理），比的是**次序和位置**：
//   · 盖上的那块里，红蓝交界被糊成混色，块外的交界还是硬的；
//   · 改动的范围垂直方向正好是那一块的上下沿；
//   · 调色和盖一块同时有时，块里的颜色和「只调色」的参照一样（这一层带上了调色 —— 调色挂在播放器视图上，这一层看不到）；
//   · 马赛克的格子从这一块的左上角起算（水平格线落在块左边 + k × 格宽，竖直格线落在块上边 + k × 格高）；
//   · 两块同时盖；盖一块撤掉之后（`CoverStack.empty`），画面回到和参照一样。
// 需要图形会话，所以**故意不在 check-all.sh 里**，同 scripts/check-filter-preview-attach.sh。跑法见 scripts/check-cover-preview-attach.sh。

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
guard arguments.count >= 7 else {
    print("用法：<binary> <redblue> <hramp> <vramp> <out-fifo> <ctl-fifo> <shot-dir>")
    exit(2)
}
let redBlue = URL(fileURLWithPath: arguments[1]), hramp = URL(fileURLWithPath: arguments[2]), vramp = URL(fileURLWithPath: arguments[3])
let outFifo = arguments[4], ctlFifo = arguments[5]
let shotDirectory = URL(fileURLWithPath: arguments[6])

let panelWidth = 200.0, panelHeight = 112.5, gap = 10.0
let columns = 3, rows = 3

/// 盖在哪一块（画布 0…1、左上原点）。**上下故意不对称**（0.15…0.60）：对称的框（0.25…0.75）翻不翻转上下都一样，
/// CA 是左下原点、归一化的框是左上原点，换算漏了这一步就抓不到。
let regionA = CGRect(x: 0.3, y: 0.15, width: 0.4, height: 0.45)

struct PanelPlan {
    var video: URL
    var covers: [CoverStack.Entry]
    var graded: Bool = false
}

@MainActor
final class Panel {
    let view = AVPlayerView()
    let cover: CoverHostView
    let attachment = FilterStackAttachment()
    let player: AVPlayer

    init(plan: PanelPlan, frame: NSRect) {
        player = AVPlayer(url: plan.video)
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.frame = frame
        cover = CoverHostView(player: player)
        cover.frame = frame
        let grade = plan.graded ? FilterStack(entries: [.init(preset: .coldIron, strength: 1)]) : FilterStack.empty
        attachment.apply(grade, to: view)
        cover.apply(CoverStack(entries: plan.covers), grade: grade)
    }
}

@MainActor
final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var panels: [Panel] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let width = panelWidth * Double(columns) + gap * Double(columns + 1)
        let height = panelHeight * Double(rows) + gap * Double(rows + 1)
        // 无边框：截图就是内容本身，不用去扣标题栏。
        window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = .black
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        root.wantsLayer = true
        window.contentView = root
        let blur = CoverStack.Entry(kind: .blur, rect: regionA, amount: 96)          // 1080 基准 96 → 面板高 112.5 上半径 10 点
        let mosaic = CoverStack.Entry(kind: .mosaic, rect: regionA, amount: 115)     // → 12 点一格
        let plans: [PanelPlan] = [
            PanelPlan(video: redBlue, covers: []),                                                          // 0 参照
            PanelPlan(video: redBlue, covers: [blur]),                                                      // 1 模糊
            PanelPlan(video: redBlue, covers: [blur], graded: true),                                        // 2 调色 + 模糊
            PanelPlan(video: redBlue, covers: [], graded: true),                                            // 3 调色参照
            PanelPlan(video: hramp, covers: [mosaic]),                                                      // 4 马赛克（横向渐变量水平格线）
            PanelPlan(video: vramp, covers: [mosaic]),                                                      // 5 马赛克（纵向渐变量竖直格线）
            PanelPlan(video: redBlue, covers: [                                                             // 6 两块
                .init(kind: .blur, rect: CGRect(x: 0.35, y: 0.1, width: 0.3, height: 0.3), amount: 96),
                .init(kind: .blur, rect: CGRect(x: 0.4, y: 0.6, width: 0.3, height: 0.3), amount: 96)
            ]),
            PanelPlan(video: redBlue, covers: [blur]),                                                      // 7 盖了又撤
            PanelPlan(video: redBlue, covers: []),                                                          // 8 参照（和 7 撤掉之后比）
        ]
        for (index, plan) in plans.enumerated() {
            let col = index % columns, row = index / columns
            let frame = NSRect(x: gap + (panelWidth + gap) * Double(col), y: gap + (panelHeight + gap) * Double(rows - 1 - row), width: panelWidth, height: panelHeight)
            let panel = Panel(plan: plan, frame: frame)
            root.addSubview(panel.view)
            if !plan.covers.isEmpty { root.addSubview(panel.cover) }
            panels.append(panel)
        }
        window.orderFrontRegardless()
        panels.forEach { $0.player.play() }
        Task { await self.drive() }
    }

    /// 和外面的脚本换手：写窗口号 → 等它拍完 → 继续。写 FIFO 和等回执都是阻塞的，不能占着主线程。
    func handshake() async {
        let id = window.windowNumber
        await Task.detached {
            try? "\(id)\n".write(toFile: outFifo, atomically: false, encoding: .utf8)
            _ = FileHandle(forReadingAtPath: ctlFifo)?.availableData
        }.value
    }

    func drive() async {
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await handshake()
        // 第二拍：面板 7 的盖一块撤掉（走生产里「播放头出了这一段」那条路）。
        panels[7].cover.apply(CoverStack.empty, grade: FilterStack.empty)
        try? await Task.sleep(nanoseconds: 600_000_000)
        await handshake()
        report()
    }

    func report() {
        guard let first = Shot(shotDirectory.appendingPathComponent("shot1.png")),
              let second = Shot(shotDirectory.appendingPathComponent("shot2.png")) else {
            check(false, "没拿到截图（要图形会话）")
            finish()
        }
        runAssertions(first: first, second: second)
        finish()
    }

    func finish() -> Never {
        if failures > 0 {
            print("✗ \(failures) of \(checks) checks failed")
            exit(1)
        }
        print("All \(checks) checks passed.")
        exit(0)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = MainActor.assumeIsolated { Delegate() }
app.delegate = delegate
app.run()
