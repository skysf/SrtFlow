import AppKit
import SwiftUI
import UniformTypeIdentifiers

// 落点路由探针：把 SwiftUI 在 macOS 上「一次拖放交给谁」测清楚。
//
// 每一格只放一种落点组合，所有回调写日志；每格的中心点（全局屏幕坐标、左上原点，
// 和 external-file-drag/replay.sh 同一套）启动时也写进日志。用法见同目录 probe.sh。
//
// 2026-09-23 靠它定的性（docs/bugfixes/2026-09-23-in-app-drops-swallowed-by-file-underlay.md）：
// 指针底下**最里面**那个落点独占这次拖放，类型对不上也不往外找（R1 / R9），
// 代理式、闭包式都收得到外部拖入（R2 / R4）。改时间线的 `.onDrop` 结构之前，
// 先在这儿把想法测一遍 —— 在 SrtFlow 里二分要慢得多，而且容易被别的落点挡着测偏。
//
// 顶上两张卡片（A / B）是 App 内 `.onDrag` 的拖源。**合成事件驱动不了它们**
// （拖动图像会跟着走，但落点一个回调都收不到），App 内那一半只能人手拖。

let logPath = CommandLine.arguments.count > 1 && CommandLine.arguments[1].hasSuffix(".log") ? CommandLine.arguments[1] : "/tmp/dropprobe.log"
func plog(_ s: String) {
    let line = "\(String(format: "%.3f", Date().timeIntervalSince1970)) \(s)\n"
    if let h = FileHandle(forWritingAtPath: logPath) {
        h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
    } else {
        try? Data(line.utf8).write(to: URL(fileURLWithPath: logPath))
    }
}

let typeA = UTType(exportedAs: "com.probe.alpha", conformingTo: .data)
let typeB = UTType(exportedAs: "com.probe.beta", conformingTo: .data)

func describe(_ info: DropInfo) -> String {
    "file=\(info.hasItemsConforming(to: [.fileURL])) A=\(info.hasItemsConforming(to: [typeA])) B=\(info.hasItemsConforming(to: [typeB]))"
}

struct LogDelegate: DropDelegate {
    let name: String
    let accepts: [UTType]
    func validateDrop(info: DropInfo) -> Bool {
        let ok = info.hasItemsConforming(to: accepts)
        plog("\(name) validate=\(ok) \(describe(info))")
        return ok
    }
    func dropEntered(info: DropInfo) { plog("\(name) entered \(describe(info))") }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .copy)
    }
    func dropExited(info: DropInfo) { plog("\(name) exited") }
    func performDrop(info: DropInfo) -> Bool {
        plog("\(name) PERFORM \(describe(info)) providers(file)=\(info.itemProviders(for: [.fileURL]).count)")
        return true
    }
}

struct ClosureDrop: ViewModifier {
    let name: String
    let accepts: [UTType]
    @State private var targeted = false
    func body(content: Content) -> some View {
        content
            .onDrop(of: accepts, isTargeted: $targeted) { providers in
                plog("\(name) PERFORM providers=\(providers.count) types=\(providers.map(\.registeredTypeIdentifiers))")
                return true
            }
            .onChange(of: targeted) { _, value in plog("\(name) isTargeted=\(value)") }
    }
}

extension View {
    func closureDrop(_ name: String, _ accepts: [UTType]) -> some View {
        modifier(ClosureDrop(name: name, accepts: accepts))
    }
    func delegateDrop(_ name: String, _ accepts: [UTType]) -> some View {
        onDrop(of: accepts, delegate: LogDelegate(name: name, accepts: accepts))
    }
    /// 把这一块的全局中心（屏幕坐标、左上原点）记进日志。
    func report(_ name: String) -> some View {
        background(GeometryReader { proxy in
            Color.clear.onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    guard let window = NSApp.windows.first(where: { $0.title == "DropProbe" }) else { return }
                    // `.global` 从**窗口**顶上（含标题栏）量起，不是从内容区量起
                    //（实测差一个 32pt 的标题栏），所以拿 window.frame 换算。
                    let local = proxy.frame(in: .global)
                    let mainH = NSScreen.screens.first!.frame.height
                    let x = window.frame.minX + local.midX
                    let y = mainH - window.frame.maxY + local.midY
                    plog("REGION \(name) center=\(Int(x)),\(Int(y))")
                }
            }
        })
    }
}

struct Box: View {
    let title: String
    let color: Color
    var body: some View {
        Text(title)
            .font(.system(size: 11))
            .multilineTextAlignment(.center)
            .frame(width: 190, height: 110)
            .background(color.opacity(0.25))
            .border(color)
    }
}

struct Chip: View {
    let label: String
    let type: UTType
    var body: some View {
        Text(label)
            .frame(width: 90, height: 40)
            .background(Color.orange)
            .onDrag {
                plog("onDrag \(label)")
                return NSItemProvider(item: label as NSString, typeIdentifier: type.identifier)
            }
    }
}

struct ProbeView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 20) {
                Chip(label: "A", type: typeA).report("chipA")
                Chip(label: "B", type: typeB).report("chipB")
            }
            HStack(spacing: 14) {
                // R1：闭包(file) 在外、代理(A) 在里 —— 同一个视图（改动前的时间线：文件落点在外）
                Box(title: "R1 same view\ninner delegate(A)\nouter closure(file)", color: .red)
                    .delegateDrop("R1.delegateA", [typeA])
                    .closureDrop("R1.closureFile", [.fileURL])
                    .report("R1")
                // R2：一个代理认两种
                Box(title: "R2 single delegate\n(file + A)", color: .blue)
                    .delegateDrop("R2.delegateFileA", [.fileURL, typeA])
                    .report("R2")
                // R3：闭包(file) 在里、代理(A) 在外（ea746c1 的垫法）
                Box(title: "R3 same view\ninner closure(file)\nouter delegate(A)", color: .green)
                    .closureDrop("R3.closureFile", [.fileURL])
                    .delegateDrop("R3.delegateA", [typeA])
                    .report("R3")
                // R4：一个闭包认两种
                Box(title: "R4 single closure\n(file + A)", color: .purple)
                    .closureDrop("R4.closureFileA", [.fileURL, typeA])
                    .report("R4")
            }
            HStack(spacing: 14) {
                // R5：代理(A) 在里、代理(B) 在外（滤镜 + 音频库的叠法）
                Box(title: "R5 same view\ninner delegate(A)\nouter delegate(B)", color: .orange)
                    .delegateDrop("R5.delegateA", [typeA])
                    .delegateDrop("R5.delegateB", [typeB])
                    .report("R5")
                // R6：跨视图 —— 里面的视图挂代理(A)，外面的视图挂代理(B)（转场行套在滚动内容里）
                VStack {
                    Box(title: "R6 inner VIEW\ndelegate(A)", color: .pink)
                        .delegateDrop("R6.innerDelegateA", [typeA])
                        .report("R6inner")
                }
                .padding(8)
                .background(Color.gray.opacity(0.2))
                .delegateDrop("R6.outerDelegateB", [typeB])
                // R7：跨视图 —— 里面闭包(file)，外面代理(A)
                VStack {
                    Box(title: "R7 inner VIEW\nclosure(file)", color: .teal)
                        .closureDrop("R7.innerClosureFile", [.fileURL])
                        .report("R7inner")
                }
                .padding(8)
                .background(Color.gray.opacity(0.2))
                .delegateDrop("R7.outerDelegateA", [typeA])
                // R8：跨视图 —— 里面代理(file+A)，外面闭包(file)
                VStack {
                    Box(title: "R8 inner VIEW\ndelegate(file+A)", color: .indigo)
                        .delegateDrop("R8.innerDelegateFileA", [.fileURL, typeA])
                        .report("R8inner")
                }
                .padding(8)
                .background(Color.gray.opacity(0.2))
                .closureDrop("R8.outerClosureFile", [.fileURL])
            }
            HStack(spacing: 14) {
                // R9：里面的视图挂 `.onDrop(of: [])`（空类型，时间线每条非主轨行的写法），外面闭包(file)
                VStack {
                    Box(title: "R9 inner VIEW\nonDrop(of: [])", color: .brown)
                        .delegateDrop("R9.innerDelegateEmpty", [])
                        .report("R9inner")
                }
                .padding(8)
                .background(Color.gray.opacity(0.2))
                .closureDrop("R9.outerClosureFile", [.fileURL])
                // R10：里面的视图没有任何落点，外面代理(file)（单一路由器挂在祖先上）
                VStack {
                    Box(title: "R10 inner VIEW\nno drop", color: .mint)
                        .report("R10inner")
                }
                .padding(8)
                .background(Color.gray.opacity(0.2))
                .delegateDrop("R10.outerDelegateFile", [.fileURL, typeA])
            }
        }
        .padding(20)
        .frame(width: 900, height: 560, alignment: .topLeading)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
plog("launched pid=\(ProcessInfo.processInfo.processIdentifier)")
let window = NSWindow(contentRect: NSRect(x: 30, y: 900 - 60 - 560, width: 900, height: 560),
                      styleMask: [.titled], backing: .buffered, defer: false)
window.title = "DropProbe"
window.contentView = NSHostingView(rootView: ProbeView())
window.level = .floating
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
