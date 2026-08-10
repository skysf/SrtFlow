import AppKit
import SwiftUI

/// Transform 数值框：文本编辑 + 紧凑上下箭头 + 鼠标横向拖调，三条互不干扰。
/// 完整合同见 docs/architecture/inspector-scrub-number-field.md。
///
/// 写入分两条路径，调用方按需接：
/// - `value`：离散写入，文本 Enter/失焦提交、箭头点击共用，每次一步撤销
///   （两者都是天然的单次动作，共用一个 setter 没问题）。
/// - `onScrubBegin`/`onScrubChanged`/`onScrubEnd`/`onScrubCancel`：连续横向
///   拖调。调用方要把前三个接到项目的 `beginLiveEdit`/`liveApply`/`endLiveEdit`
///   上，`onScrubCancel` 接 `cancelLiveEdit`——**不能**接到 `value` 上，否则
///   每个鼠标事件都会走一次离散提交，撤销栈被拖成几十步、AV 合成也会跟着
///   重建几十次。
///
/// 拖调手势：按住约 0.175s 后横向移动超过阈值才进入拖调。等待期内的鼠标
/// 位移会被**消费掉**（不交给文本框做拖选），松手一律按普通点击处理——
/// 进入文本编辑、全选待改；文本拖选只在已经处于编辑态时由原生行为提供。
/// Escape、App 失焦、窗口/视图失效、mouseUp 丢失都会取消拖调并恢复原值。
struct InspectorScrubbableNumberField: View {
    var value: Binding<Double>
    var range: ClosedRange<Double>
    var fractionDigits: Int = 0
    var width: Double = 52
    var onScrubBegin: () -> Void = {}
    var onScrubChanged: (Double) -> Void = { _ in }
    var onScrubEnd: () -> Void = {}
    var onScrubCancel: () -> Void = {}

    @Environment(\.locale) private var locale

    private static let stepperWidth: Double = 11
    private static let gap: Double = 2

    var body: some View {
        // resizeLeftRight 光标由 AppKit 字段自己的 cursor rect 提供（只盖数字
        // 区，不盖箭头，编辑态自动回文本光标），这里不做任何 push/pop。
        HStack(spacing: Self.gap) {
            ScrubbableNumberFieldRepresentable(
                value: value,
                range: range,
                fractionDigits: fractionDigits,
                locale: locale,
                onScrubBegin: onScrubBegin,
                onScrubChanged: onScrubChanged,
                onScrubEnd: onScrubEnd,
                onScrubCancel: onScrubCancel
            )
            .frame(width: max(0, width - Self.stepperWidth - Self.gap))
            stepperArrows
        }
        .frame(width: width)
    }

    private var stepperArrows: some View {
        VStack(spacing: 0) {
            Button {
                step(by: 1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(value.wrappedValue >= range.upperBound)
            .instantHelp("Increase by 1")

            Button {
                step(by: -1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(value.wrappedValue <= range.lowerBound)
            .instantHelp("Decrease by 1")
        }
        .buttonStyle(.borderless)
        .controlSize(.mini)
        .font(.system(size: 7, weight: .semibold))
        .frame(width: Self.stepperWidth)
    }

    /// 箭头是离散动作：当前值 ± 1，一次点击一步撤销（走 `value` 的 setter）。
    private func step(by amount: Double) {
        let next = min(max(value.wrappedValue + amount, range.lowerBound), range.upperBound)
        guard next.isFinite else { return }
        value.wrappedValue = next
    }
}

// MARK: - AppKit 承载

/// 桥接自定义 `NSTextField`：SwiftUI 的 `TextField` 没有「先按住、再横向拖」
/// 这种手势分流的钩子，普通点击一定会被它当成文本框点击/拖选文字。
private struct ScrubbableNumberFieldRepresentable: NSViewRepresentable {
    var value: Binding<Double>
    var range: ClosedRange<Double>
    var fractionDigits: Int
    var locale: Locale
    var onScrubBegin: () -> Void
    var onScrubChanged: (Double) -> Void
    var onScrubEnd: () -> Void
    var onScrubCancel: () -> Void

    func makeNSView(context: Context) -> ScrubbableNumberField {
        let field = ScrubbableNumberField()
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.controlSize = .small
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.alignment = .right
        updateCallbacks(field)
        updateFormat(field)
        field.currentValue = value.wrappedValue
        field.stringValue = field.numberFormatter.string(from: NSNumber(value: value.wrappedValue)) ?? ""
        return field
    }

    func updateNSView(_ nsView: ScrubbableNumberField, context: Context) {
        updateCallbacks(nsView)
        updateFormat(nsView)
        // 编辑中或拖调中都别用外部值覆盖：编辑中会打断正在输入的文字，
        // 拖调中场内已经在追踪循环里直接写 stringValue 了，这里
        // 再写一次只会跟它抢（两边算出来的字符串理论一致，但没必要抢）。
        guard !nsView.isActivelyEditing, !nsView.isScrubbing else { return }
        nsView.currentValue = value.wrappedValue
        nsView.stringValue = nsView.numberFormatter.string(from: NSNumber(value: value.wrappedValue)) ?? nsView.stringValue
    }

    private func updateCallbacks(_ field: ScrubbableNumberField) {
        field.minValue = range.lowerBound
        field.maxValue = range.upperBound
        field.fractionDigits = fractionDigits
        field.onCommit = { newValue in value.wrappedValue = newValue }
        field.onScrubBegin = onScrubBegin
        field.onScrubChanged = onScrubChanged
        field.onScrubEnd = onScrubEnd
        field.onScrubCancel = onScrubCancel
    }

    private func updateFormat(_ field: ScrubbableNumberField) {
        field.numberFormatter.locale = locale
        field.numberFormatter.maximumFractionDigits = fractionDigits
        field.numberFormatter.minimumFractionDigits = 0
    }
}

/// 承载「文本编辑」与「横向拖调」两种手势的文本框。
///
/// 手势分流只在**未编辑**状态的 `mouseDown` 里做（已经在编辑态时——见
/// `isActivelyEditing`——完全不介入，点击/拖选文字/双击选词全是原生行为）。
/// 按下后进入追踪循环：约 0.175s 的等待期内位移一律消费掉；等待期满后横向
/// 位移超过阈值进入拖调。松手且没进入过拖调 = 普通点击 → 进入编辑并全选。
/// Escape / App 失焦 / 窗口或视图失效 / mouseUp 丢失 = 取消 → 恢复按下前的
/// 值并回调 `onScrubCancel`。
private final class ScrubbableNumberField: NSTextField, NSTextFieldDelegate {
    var minValue: Double = 0
    var maxValue: Double = 1
    var fractionDigits: Int = 0
    /// SwiftUI 侧最后一次推下来的值，拖调手势起点、箭头步进都以它为准。
    var currentValue: Double = 0
    var onCommit: ((Double) -> Void)?
    var onScrubBegin: (() -> Void)?
    var onScrubChanged: ((Double) -> Void)?
    var onScrubEnd: (() -> Void)?
    var onScrubCancel: (() -> Void)?
    let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        // 像素/百分比/角度都不要千位分隔（"-1,920" 又宽又怪）。
        formatter.usesGroupingSeparator = false
        return formatter
    }()

    private(set) var isScrubbing = false

    /// 这个字段**此刻真的在编辑**吗：窗口第一响应者是 field editor、且它正
    /// 服务于本字段。不能用 `currentEditor()` 判——实测窗口里任何一个字段
    /// 编辑过一次之后（共享 field editor 被创建），它对**没在编辑**的字段也
    /// 返回非 nil，手势入口就永远进不去了。
    var isActivelyEditing: Bool {
        guard let editor = window?.firstResponder as? NSTextView, editor.isFieldEditor else { return false }
        return (editor.delegate as AnyObject?) === self
    }

    private static let holdDelay: TimeInterval = 0.175
    private static let moveThreshold: CGFloat = 3
    /// 追踪循环的取事件超时：每次醒来查一遍取消条件（App 失焦、视图脱窗、
    /// mouseUp 丢失），不做无限期无取消检测的等待。
    private static let pollInterval: TimeInterval = 0.1
    /// 横向 1pt = 数值 1 单位（Position/px、Scale·Opacity/%、Rotation/°都按 1）。
    private static let sensitivity: Double = 1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        delegate = self
        // 拒绝一切**自动**聚焦：检查器一出现，AppKit/SwiftUI 的焦点系统会把
        // 第一响应者塞给某个输入框，字段凭空进入编辑态，拖调入口就永远
        // 走不到（编辑态的交互全数交回原生文本处理）。只有用户真点击时
        // （下面 mouseDown 的普通点击分支）才临时放行。
        refusesFirstResponder = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: 光标

    /// resizeLeftRight 只盖数字框自己（不含旁边的箭头按钮），编辑态交回
    /// 原生文本光标。cursor rect 随视图销毁自动失效，不存在全局 push/pop
    /// 的栈错位问题。
    override func resetCursorRects() {
        if isActivelyEditing {
            super.resetCursorRects()
        } else {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }
    }

    // MARK: 手势入口
    //
    // 用 `NSWindow.nextEvent` 的取事件追踪循环——这是 AppKit 里手势判定的
    // 标准写法，从 mouseDown 开始独占后续事件直到松手或取消，能保证这场
    // 手势的每一个 mouseDragged/mouseUp 都被看到。早前用
    // `addLocalMonitorForEvents` 旁听同一批事件，实测时序不可靠（拖动完全
    // 不触发，松手总落回点击分支）；`nextEvent` 直接从事件队列取，没这个坑。
    // 取事件带短超时，每次醒来都查取消条件，绝不无限期阻塞。

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, !isActivelyEditing else {
            super.mouseDown(with: event)
            return
        }
        guard let hostWindow = window else { return }

        let startX = event.locationInWindow.x
        let startValue = currentValue
        let armTime = Date(timeIntervalSinceNow: Self.holdDelay)
        var scrubbing = false
        // 拖调的**有效位移起点**：长按期满那一刻的鼠标位置。等待期内没动就是
        // startX；等待期内有被消费的位移，起点跟着挪到最后一个等待期位置——
        // 长按期满后的位移必须**全部**计入，期满前的全部丢弃。
        var originX = startX
        // 拖调换算：`当前值 = refValue + (鼠标当前 x − refX) × 灵敏度 × refScale`。
        // refX/refValue 是固定参照点（有效位移起点、或修饰键切换那一刻），
        // 位移永远相对参照点算绝对量，不逐帧累加增量。
        var refX = startX
        var refValue = startValue
        var refScale = 1.0
        /// 最后一次实际应用（量化 + 夹紧后）的值。修饰键切换时从它重定基准，
        /// 不携带未量化小数或越过上下限的隐藏余量——切换瞬间数值不跳，
        /// 从边界往回拖也立即响应。
        var lastApplied = startValue

        enum Outcome { case clicked, completed, cancelled }
        // 所有非 mouseUp 的退出路径（Escape、失焦、视图失效、mouseUp 丢失）
        // 都是取消。
        var outcome = Outcome.cancelled

        // 收尾集中在 defer：无论哪条路径退出，isScrubbing 一定复位、
        // 终结回调恰好发一次。
        defer {
            isScrubbing = false
            switch outcome {
            case .completed:
                onScrubEnd?()
            case .cancelled:
                if scrubbing {
                    currentValue = startValue
                    stringValue = numberFormatter.string(from: NSNumber(value: startValue)) ?? stringValue
                    onScrubCancel?()
                }
                // 还没进入拖调就取消（按住时按了 Esc 等）：什么都没改过，
                // 也不进入编辑。
            case .clicked:
                // 普通点击：进入文本编辑，全选待改（数字框的常见习惯：
                // 点一下就能直接重新输入）。点击是唯一放行聚焦的入口；
                // 编辑结束时在 controlTextDidEndEditing 里恢复拒绝。
                refusesFirstResponder = false
                selectText(nil)
            }
        }

        func applyDrag(currentX: CGFloat, flags: NSEvent.ModifierFlags) {
            let scale = Self.modifierScale(flags)
            if scale != refScale {
                refX = currentX
                refValue = lastApplied
                refScale = scale
            }
            let raw = refValue + Double(currentX - refX) * Self.sensitivity * refScale
            let candidate = Self.quantize(raw, fractionDigits: fractionDigits, range: minValue...maxValue)
            guard candidate.isFinite else { return }
            lastApplied = candidate
            currentValue = candidate
            stringValue = numberFormatter.string(from: NSNumber(value: candidate)) ?? stringValue
            onScrubChanged?(candidate)
        }

        trackingLoop: while true {
            // 取消检测：视图被摘出窗口 / 窗口没了 / App 失焦。
            // App 失焦**不能**用 `NSApp.isActive` 判：追踪循环只出列鼠标/键盘
            // 事件，失焦的 appKitDefined 事件滞留在队列里没被处理，
            // `NSApp.isActive` 在循环内永远是 true（实测 Finder 激活后照常
            // 完成手势）。`NSWorkspace.frontmostApplication` 问的是系统实况，
            // 不依赖本进程的事件处理。
            guard self.window === hostWindow, hostWindow.isVisible,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier
                      == ProcessInfo.processInfo.processIdentifier else {
                break trackingLoop
            }
            guard let next = hostWindow.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp, .keyDown],
                until: Date(timeIntervalSinceNow: Self.pollInterval),
                inMode: .eventTracking,
                dequeue: true
            ) else {
                // 队列空。左键已经不按着说明 mouseUp 丢了（被别的窗口吃掉
                // 之类），按取消收场。
                if NSEvent.pressedMouseButtons & 1 == 0 {
                    break trackingLoop
                }
                continue
            }

            switch next.type {
            case .leftMouseDragged:
                let currentX = next.locationInWindow.x
                // 等待期内的位移消费掉（不算拖调、不交给文本框拖选），但
                // 有效位移起点跟着挪：期满后只结算期满之后的位移。
                guard Date() >= armTime else {
                    originX = currentX
                    continue
                }
                if !scrubbing {
                    guard abs(currentX - originX) >= Self.moveThreshold else { continue }
                    scrubbing = true
                    isScrubbing = true
                    // 参照点 = 有效位移起点（不是本事件位置！否则首个事件的
                    // 位移被吞，单事件拖动就完全无效）。refScale 取本事件的
                    // 修饰键，applyDrag 里才不会把首个事件误判成修饰键切换。
                    refX = originX
                    refValue = startValue
                    lastApplied = startValue
                    refScale = Self.modifierScale(next.modifierFlags)
                    onScrubBegin?()
                    // 不 continue：首个有效事件的位移立即结算。
                }
                applyDrag(currentX: currentX, flags: next.modifierFlags)
            case .leftMouseUp:
                // 拖调中：按 mouseUp 的最终坐标再结算一次，事件合并吞掉的
                // 最后一段不能丢。
                if scrubbing {
                    applyDrag(currentX: next.locationInWindow.x, flags: next.modifierFlags)
                }
                outcome = scrubbing ? .completed : .clicked
                break trackingLoop
            case .keyDown:
                // Escape 取消；按住期间其它按键没有意义，一并消费。
                if next.keyCode == 53 {
                    break trackingLoop
                }
            default:
                break
            }
        }
    }

    private static func modifierScale(_ flags: NSEvent.ModifierFlags) -> Double {
        var scale = 1.0
        if flags.contains(.shift) { scale *= 0.1 }
        if flags.contains(.option) { scale *= 10 }
        return scale
    }

    /// 按字段的显示精度量化：整数字段落在整数上，Rotation（1 位小数）落在
    /// 0.1 上，再夹进值域。
    private static func quantize(_ value: Double, fractionDigits: Int, range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return range.lowerBound }
        let granularity = pow(10, -Double(fractionDigits))
        let stepped = (value / granularity).rounded() * granularity
        return min(max(stepped, range.lowerBound), range.upperBound)
    }

    // MARK: NSTextFieldDelegate（编辑态下的原生行为）

    func controlTextDidBeginEditing(_ obj: Notification) {
        window?.invalidateCursorRects(for: self)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitTypedText()
        refusesFirstResponder = true
        window?.invalidateCursorRects(for: self)
    }

    /// Return 直接提交并失焦（失焦本身也会再触发一次 `controlTextDidEndEditing`，
    /// 但 `commitTypedText` 用同一个已提交的值调用 `onCommit` 是幂等的，
    /// 上层 `perform` 会因为 `next == before` 直接跳过，不会重复记撤销）。
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
        window?.makeFirstResponder(nil)
        return true
    }

    private func commitTypedText() {
        guard let parsed = numberFormatter.number(from: stringValue)?.doubleValue, parsed.isFinite else {
            stringValue = numberFormatter.string(from: NSNumber(value: currentValue)) ?? stringValue
            return
        }
        let clamped = min(max(parsed, minValue), maxValue)
        currentValue = clamped
        stringValue = numberFormatter.string(from: NSNumber(value: clamped)) ?? stringValue
        onCommit?(clamped)
    }
}
