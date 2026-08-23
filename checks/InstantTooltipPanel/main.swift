import AppKit
import SwiftUI

// 提示面板的**落点自检**：给一个已知位置的锚点，量提示面板真实落在哪、以及
// 摆好之后会不会自己动。编译方式见 scripts/check-instant-tooltip-panel.sh。
//
// 回归（docs/bugfixes/2026-08-12-instant-tooltip-first-show-far-off.md）：
// `NSHostingView` 直接当 `NSPanel.contentView` 时，会把自己的尺寸约束灌成窗口的
// `contentMinSize` —— 一条 24pt 高的提示报出的 min 高度是 332。AppKit 下一轮
// 排版就把面板撑到 332 高，气泡在里面垂直居中，肉眼看到的是「提示掉到控件下方
// 几百点的地方」。所以这里量的不是「摆位算得对不对」，而是**摆完之后还在不在**。
//
// 不需要 hover：`.onHover` 对合成鼠标事件不响应（见 docs/testing/），但
// `InstantTooltipController.show(label:shortcut:from:)` 是生产路径本身，
// 直接调它就绕开了鼠标。

var failures = 0
var checks = 0

func check(_ condition: Bool, _ message: String, line: Int = #line) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL [line \(line)] \(message)")
    }
}

/// 一条单行提示的合理高度上限。撑坏时实测是 332，正常是 24～30。
let maxPlausibleTooltipHeight: CGFloat = 60
/// 提示与控件之间的间距，与 `InstantTooltip.swift` 的摆位规则一致。
let gap: CGFloat = 6

@MainActor
func makeAnchor(in windowFrame: CGRect, at local: CGRect) -> (TooltipAnchorBox, NSWindow) {
    let window = NSWindow(
        contentRect: windowFrame,
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    let view = NSView(frame: local)
    window.contentView?.addSubview(view)
    let box = TooltipAnchorBox()
    box.view = view
    return (box, window)
}

/// 弹一次提示，返回（刚摆好的矩形，跑完一轮排版之后的矩形）。
@MainActor
func showAndSettle(_ box: TooltipAnchorBox, label: String) -> (CGRect, CGRect)? {
    InstantTooltipController.shared.show(label: Text(verbatim: label), shortcut: "A / B", from: box)
    guard let placed = InstantTooltipController.shared.panelFrameForChecks else { return nil }
    // 撑大发生在下一轮排版，不是同步的 —— 必须放 runloop 跑一圈再量。
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    guard let settled = InstantTooltipController.shared.panelFrameForChecks else { return nil }
    return (placed, settled)
}

@MainActor
func run() {
    let app = NSApplication.shared
    // .accessory：自检不抢用户焦点（面板还是要真 orderFront，那是生产路径）。
    app.setActivationPolicy(.accessory)

    guard let screen = NSScreen.main else {
        print("FAIL 没有可用的屏幕，量不了落点")
        failures += 1
        return
    }
    let visible = screen.visibleFrame

    // ---- 1. 控件在屏幕中部：提示摆到它正下方，并且**摆完不许自己动** ----
    let midFrame = CGRect(x: visible.midX - 300, y: visible.midY - 200, width: 600, height: 400)
    let (box, window) = makeAnchor(in: midFrame, at: CGRect(x: 40, y: 300, width: 20, height: 18))
    guard let anchor = box.screenFrame else {
        print("FAIL 锚点量不到 screenFrame（视图没在窗口里？）")
        failures += 1
        return
    }

    guard let (placed, settled) = showAndSettle(box, label: "Mouse tool: Select or Split") else {
        print("FAIL 第一次就没弹出面板")
        failures += 1
        return
    }
    check(placed == settled, "面板摆好之后不许自己改尺寸/挪位置：摆位 \(placed) → 稳定 \(settled)")
    check(
        settled.height <= maxPlausibleTooltipHeight,
        "单行提示的面板高度不该超过 \(maxPlausibleTooltipHeight)：实际 \(settled.height)"
    )
    check(
        abs(settled.maxY - (anchor.minY - gap)) < 0.5,
        "提示上边应贴在控件下方 \(gap)pt：期望 \(anchor.minY - gap)，实际 \(settled.maxY)"
    )
    check(
        abs(settled.midX - anchor.midX) < 1,
        "提示应与控件水平居中对齐：控件 \(anchor.midX)，提示 \(settled.midX)"
    )

    // ---- 2. 换一次内容再弹：复用同一个面板，不许残留上一次的尺寸 ----
    InstantTooltipController.shared.hide(owner: box)
    guard let (placed2, settled2) = showAndSettle(box, label: "Split at playhead") else {
        print("FAIL 第二次没弹出面板")
        failures += 1
        return
    }
    check(placed2 == settled2, "复用面板时同样不许自己变：摆位 \(placed2) → 稳定 \(settled2)")
    check(
        settled2.height <= maxPlausibleTooltipHeight,
        "复用面板后高度仍要正常：实际 \(settled2.height)"
    )
    check(
        abs(settled2.maxY - (anchor.minY - gap)) < 0.5,
        "复用面板后仍贴在控件下方：期望 \(anchor.minY - gap)，实际 \(settled2.maxY)"
    )
    InstantTooltipController.shared.hide(owner: box)

    // ---- 3. 控件贴着屏幕底边：提示翻到控件上方，不许被屏幕边缘切掉 ----
    let bottomFrame = CGRect(x: visible.midX - 300, y: visible.minY, width: 600, height: 400)
    let (bottomBox, bottomWindow) = makeAnchor(
        in: bottomFrame, at: CGRect(x: 40, y: 2, width: 20, height: 18)
    )
    guard let bottomAnchor = bottomBox.screenFrame,
          let (_, bottomSettled) = showAndSettle(bottomBox, label: "Mouse tool: Select or Split")
    else {
        print("FAIL 贴底控件没弹出面板")
        failures += 1
        return
    }
    check(
        abs(bottomSettled.minY - (bottomAnchor.maxY + gap)) < 0.5,
        "下方放不下时要翻到控件上方：期望 \(bottomAnchor.maxY + gap)，实际 \(bottomSettled.minY)"
    )
    check(
        bottomSettled.minY >= visible.minY,
        "提示不许掉到屏幕可见区域之外：可见区下边 \(visible.minY)，提示下边 \(bottomSettled.minY)"
    )
    InstantTooltipController.shared.hide(owner: bottomBox)

    // ---- 4. 全局打断必须收起提示（对话框悬浮回归） ----
    //
    // 由来（docs/bugfixes/2026-08-23-tooltip-survives-open-panel.md）：提示只靠
    // 控件的 hover(false) 收，点「打开工程」弹出文件对话框后，模态会话里 hover
    // 退出根本不派发，提示一直悬浮在对话框上面。修复是面板可见期间挂两条打断：
    // 任何窗口失去 key、任何鼠标按下/按键/滚轮。这里把两条都真触发一遍。
    //
    // 4a. 窗口失去 key（对话框弹出、切窗口都会走到）。通知就是生产观察者的
    //     订阅合同，直接发它 —— 不用真弹 NSOpenPanel（模态会话会卡住自检）。
    if showAndSettle(box, label: "Open an existing .srtflowproj file") != nil {
        check(
            InstantTooltipController.shared.panelIsVisibleForChecks,
            "打断用例的前提：面板此刻应当可见"
        )
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        check(
            !InstantTooltipController.shared.panelIsVisibleForChecks,
            "窗口失去 key（对话框弹出）后提示必须收起，不能悬浮在对话框上面"
        )
    } else {
        print("FAIL 打断用例没弹出面板")
        failures += 1
    }

    // 4b. 鼠标按下（点按钮那一下）。走 NSApp.sendEvent —— 本地事件监听挂在
    //     应用派发这条路上，这就是生产路径。
    if showAndSettle(box, label: "Open an existing .srtflowproj file") != nil {
        check(
            InstantTooltipController.shared.panelIsVisibleForChecks,
            "点击打断用例的前提：面板此刻应当可见"
        )
        if let click = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: CGPoint(x: 50, y: 310),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) {
            app.sendEvent(click)
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            check(
                !InstantTooltipController.shared.panelIsVisibleForChecks,
                "鼠标按下后提示必须收起（系统 tooltip 同款语义）"
            )
        } else {
            print("FAIL 造不出合成鼠标事件")
            failures += 1
        }
    } else {
        print("FAIL 点击打断用例没弹出面板")
        failures += 1
    }

    // 4c. 打断之后不许失灵：正常 hover 路径还能再弹出来。
    if showAndSettle(box, label: "Split at playhead") != nil {
        check(
            InstantTooltipController.shared.panelIsVisibleForChecks,
            "打断收起之后，下一次 show 必须照常弹出"
        )
        InstantTooltipController.shared.hide(owner: box)
    } else {
        print("FAIL 打断后再弹失败")
        failures += 1
    }

    window.close()
    bottomWindow.close()
}

MainActor.assumeIsolated { run() }

if failures == 0 {
    print("All \(checks) checks passed.")
} else {
    print("\(failures) of \(checks) checks FAILED.")
    exit(1)
}
