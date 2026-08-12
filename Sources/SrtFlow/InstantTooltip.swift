import AppKit
import SwiftUI

// 全 App 的即时提示：鼠标一进控件就弹，移开就没，右边挂快捷键键帽。
//
// 为什么不用系统的 `.help()`：NSView 的 toolTip 有约 1 秒首次延迟，延迟由系统
// 私有的 NSToolTipManager 管，没有公开 API 能调。要「立刻出现」只能自己画一层。
// 长期约束见 docs/architecture/instant-tooltips.md。

// MARK: - 快捷键

/// 提示里显示的快捷键，以及要不要顺手把键盘等价符也挂上。
///
/// **显示和挂载出自同一个值**，所以「提示里写着 ⌘B、实际按 ⌘B 没反应」这种
/// 漂移在调用点就不可能发生 —— 两者只有一个来源。
struct HelpShortcut: Equatable, Sendable {
    /// 给用户看的样子，例如 `⌘B`、`⇧⌘F`、`M`。
    let display: String
    /// 要挂的键盘等价符；nil = **只显示不挂载**。
    let key: Character?
    let modifiers: EventModifiers

    private init(display: String, key: Character?, modifiers: EventModifiers) {
        self.display = display
        self.key = key
        self.modifiers = modifiers
    }

    static func command(_ label: Character) -> HelpShortcut {
        HelpShortcut(
            display: "⌘\(label.uppercased())",
            key: Character(label.lowercased()),
            modifiers: [.command]
        )
    }

    static func commandShift(_ label: Character) -> HelpShortcut {
        HelpShortcut(
            display: "⇧⌘\(label.uppercased())",
            key: Character(label.lowercased()),
            modifiers: [.command, .shift]
        )
    }

    /// ⌘⏎（压缩 / 烧录 / 批量转换那几个「开始」按钮）。
    static let commandReturn = HelpShortcut(display: "⌘⏎", key: "\r", modifiers: [.command])

    /// 对话框的默认按钮。等价符由调用点的 `.keyboardShortcut(.defaultAction)`
    /// 提供，这里**只负责显示** —— 重复挂一次会让同一个键有两个响应者。
    static let defaultAction = HelpShortcut(display: "⏎", key: nil, modifiers: [])

    /// 无修饰单键（空格、M、A、B、V、⌫）：**只显示**。
    ///
    /// 无修饰的键盘等价符会抢走文本框的输入 —— 用户在字幕里打一个 "m" 就变成
    /// 打标记。这些键一律由 `VideoEditView.handleEvent` 的事件监听接，那边会先
    /// 让开正在打字的输入框。
    static func plain(_ label: String) -> HelpShortcut {
        HelpShortcut(display: label, key: nil, modifiers: [])
    }
}

// MARK: - 修饰符

extension View {
    /// 鼠标一进来就弹提示，移开就消失。带快捷键时右边挂一个键帽，并顺手把键盘
    /// 等价符挂上（`HelpShortcut.key` 为 nil 的除外）。
    ///
    /// 全仓库不再直接用 `.help(`（那是系统的延迟提示），扫描守卫钉着。
    func instantHelp(_ text: LocalizedStringKey, shortcut: HelpShortcut? = nil) -> some View {
        modifier(InstantHelpModifier(label: Text(text), shortcut: shortcut))
    }

    /// 内容是运行期算出来的字符串（路径、素材名、错误文案）时用这个重载。
    /// 走 `verbatim`，**不**拿它当本地化键去查表 —— 系统的 `.help` 也是这么
    /// 分的两个重载，改成查表会把用户的文件名当成 key 去翻译。
    func instantHelp<S: StringProtocol>(_ text: S, shortcut: HelpShortcut? = nil) -> some View {
        modifier(InstantHelpModifier(label: Text(verbatim: String(text)), shortcut: shortcut))
    }
}

private struct InstantHelpModifier: ViewModifier {
    let label: Text
    let shortcut: HelpShortcut?

    /// 装着锚点视图的盒子。提示要按控件在**屏幕**上的位置摆，而屏幕坐标只有
    /// AppKit 那边算得准（SwiftUI 的 `.global` 是窗口坐标，还得自己去掉标题栏，
    /// 换算写错一次就是全 App 的提示都偏）。
    @State private var anchor = TooltipAnchorBox()

    func body(content: Content) -> some View {
        withShortcut(content)
            // 用 background 不用 overlay：overlay 铺在控件上面，会切走 SwiftUI
            // 侧的手势区域。
            .background(TooltipAnchorLayer(box: anchor))
            // 事件走 SwiftUI 的 hover —— 这个 App 里它是已经跑通的机制（标记
            // 帽子的气泡、裁切把手的光标、行高拖调都靠它）。
            //
            // 试过 AppKit 的 NSTrackingArea，装在 SwiftUI 的 background 里量出
            // 来的 `visibleRect` 是错的：20×18 的控件报出 1127×363。没有实证
            // 支撑的机制不进生产。
            .onHover { inside in
                if inside {
                    InstantTooltipController.shared.show(
                        label: label, shortcut: shortcut?.display, from: anchor
                    )
                } else {
                    InstantTooltipController.shared.hide(owner: anchor)
                }
            }
    }

    @ViewBuilder
    private func withShortcut(_ content: Content) -> some View {
        if let shortcut, let key = shortcut.key {
            content.keyboardShortcut(KeyEquivalent(key), modifiers: shortcut.modifiers)
        } else {
            content
        }
    }
}

// MARK: - 锚点

/// 一枚身份，兼放锚点视图的弱引用。
///
/// `hide` 要按它核对归属：鼠标从 A 划到 B 时，SwiftUI 先给 B 发 hover(true)
/// 再给 A 发 hover(false)。不核对的话，A 的退出会把 B 刚弹出来的提示关掉 ——
/// 表现为快速扫过工具栏时提示随机不出现。
final class TooltipAnchorBox {
    weak var view: NSView?

    /// 控件在屏幕上的位置。视图还没上屏时是 nil。
    var screenFrame: CGRect? {
        guard let view, let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }
}

private struct TooltipAnchorLayer: NSViewRepresentable {
    let box: TooltipAnchorBox

    func makeNSView(context: Context) -> NSView {
        let view = TooltipAnchorView()
        box.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        box.view = view
    }

    static func dismantleNSView(_ view: NSView, coordinator: ()) {
        // 视图被拆掉时提示不能留在屏幕上（切栏目、关面板都会走到这）。
        InstantTooltipController.shared.hideIfOwned(by: view)
    }
}

private final class TooltipAnchorView: NSView {
    /// 这一层只用来量位置，**绝不能吃点击**：它和控件同区域，吃了事件按钮就
    /// 按不动了。仓库里 `TimelineZoomReferenceView` 同一个写法。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - 提示面板

/// 全 App 共用**一个**提示面板。
///
/// 一个控件一个面板的话，扫过工具栏会瞬间造出十几个窗口；共用一个还顺带解决了
/// 「上一个还没关、下一个已经弹出来」的重叠。
@MainActor
final class InstantTooltipController {
    static let shared = InstantTooltipController()

    private var panel: NSPanel?
    private weak var owner: TooltipAnchorBox?

    private init() {}

    func show(label: Text, shortcut: String?, from box: TooltipAnchorBox) {
        // 位置量不出来（视图还没上屏）就别弹一个飘在屏幕角落的提示。
        guard let anchor = box.screenFrame, let screen = box.view?.window?.screen else { return }
        owner = box

        let panel = panel ?? makePanel()
        self.panel = panel

        let hosting = NSHostingView(
            rootView: TooltipContent(label: label, shortcut: shortcut).appLanguage()
        )
        // 取 fittingSize 之前必须先排一次版，否则拿到的是零，面板会被摆成一个
        // 看不见的点 —— 表现为「提示根本不出现」。
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        guard size.width > 1, size.height > 1 else { return }
        // **NSHostingView 绝不能直接当 contentView**：它会把自己的尺寸约束灌成
        // 窗口的 contentMinSize/contentMaxSize（实测一条 24pt 高的提示报出
        // minSize 高 332），AppKit 下一轮排版就把面板撑到那个高度，气泡在里面
        // 垂直居中 —— 肉眼看到的是提示掉到控件下方几百点的地方。
        // 中间垫一层普通 NSView，尺寸就只由这里的 setFrame 说了算。
        let container = NSView(frame: CGRect(origin: .zero, size: size))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container

        let visible = screen.visibleFrame
        var origin = CGPoint(x: anchor.midX - size.width / 2, y: anchor.minY - size.height - 6)
        // 下面放不下就翻到控件上方（工具栏贴着窗口底边时会走到这）。
        if origin.y < visible.minY { origin.y = anchor.maxY + 6 }
        origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)

        panel.setFrame(CGRect(origin: origin, size: size), display: false)
        panel.orderFront(nil)
    }

    func hide(owner box: TooltipAnchorBox) {
        guard owner === box else { return }
        owner = nil
        panel?.orderOut(nil)
    }

    fileprivate func hideIfOwned(by view: NSView) {
        guard let owner, owner.view === view else { return }
        hide(owner: owner)
    }

    /// 自检读取用：提示面板当前的屏幕矩形（nil = 还没建过面板）。
    /// `checks/InstantTooltipPanel` 靠它盯住「摆好之后不许自己变尺寸」。
    var panelFrameForChecks: CGRect? { panel?.frame }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        // 提示自己绝不能挡住鼠标：挡住就会立刻触发下面控件的 hover(false)，
        // 提示消失 → 鼠标回到控件 → 又弹出来，肉眼看到的是闪烁。
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = true
        // 「立刻出现」的另一半：默认的淡入动画会让它慢半拍。
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        return panel
    }
}

private struct TooltipContent: View {
    let label: Text
    let shortcut: String?

    var body: some View {
        HStack(spacing: 6) {
            label
                .font(.system(size: 11))
                .foregroundStyle(.primary)
            if let shortcut {
                Text(shortcut)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 3))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: 320, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.12))
        }
    }
}
