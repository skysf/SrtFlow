import AppKit
import Foundation
import SrtFlowCore
import SwiftUI

/// 录制中的浮动控制窗：红点、已录时长、Stop（计划 §11.3）。
///
/// 几个硬要求：
/// - **必须能拿到 `CGWindowID`** —— 整屏/区域来源要把它放进
///   `SCContentFilter(display:excludingWindows:)`，否则控制窗会录进成片
///   （Phase 0 门槛 9 已验证排除有效）。
/// - 只排除这一个 panel，**不排除 SrtFlow 主窗口**（用户要录产品演示）。
/// - 可移动、跨 Space、可在全屏之上（`.canJoinAllSpaces` +
///   `.fullScreenAuxiliary`），否则用户切到全屏应用就按不到 Stop。
/// - **倒计时窗不在排除集里**：它在 capture 开始前就销毁了（计划 §11.2-9）。
@available(macOS 15.0, *)
@MainActor
final class ScreenRecordingControlPanel {

    private let panel: NSPanel
    private let model: Model

    /// SwiftUI 侧读的状态。
    @MainActor
    final class Model: ObservableObject {
        @Published var elapsed: TimeInterval = 0
        /// 倒计时剩余秒数。nil = 不在倒计时。
        @Published var countdown: Int?
        @Published var isFinalizing = false
        /// 磁盘空间跌破警戒线时的提示（nil = 正常）。
        @Published var warning: String?
        var onStop: () -> Void = {}
    }

    /// 供 `excludingWindows` 使用的窗口号。
    var windowID: CGWindowID { CGWindowID(panel.windowNumber) }

    init(onStop: @escaping () -> Void) {
        model = Model()
        model.onStop = onStop

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 232, height: 44),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        // 浮在普通窗之上，但不抢激活 —— 录制中用户还要操作别的应用。
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        // **把控制窗从任何屏幕捕获里摘出去。**
        //
        // 这比「查 SCShareableContent 拿 windowID 再放进 excludingWindows」可靠得多：
        // 后者需要**广域**屏幕录制授权，而 picker 这条路的全部意义就是不要广域授权
        // （用户只授权了他选中的那块内容）。真机首测就死在那一步。
        // `sharingType = .none` 由窗口服务器保证，不依赖任何授权、也不会有
        // 「窗口还没进可分享列表」的竞态。
        panel.sharingType = .none
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: ControlPanelView(model: model))
        positionAtTopCenter()
    }

    private func positionAtTopCenter() {
        guard let screen = NSScreen.main else { return }
        let frame = panel.frame
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - frame.width / 2,
            y: visible.maxY - frame.height - 12
        ))
    }

    /// 显示并**确保已经有 windowID** —— 调用方拿到后才能构造排除 filter。
    func show() {
        panel.orderFrontRegardless()
    }

    func update(elapsed: TimeInterval) { model.elapsed = elapsed }
    func setCountdown(_ remaining: Int?) { model.countdown = remaining }
    func setFinalizing(_ value: Bool) { model.isFinalizing = value }
    func setWarning(_ text: String?) { model.warning = text }

    func close() {
        panel.orderOut(nil)
    }
}

@available(macOS 15.0, *)
private struct ControlPanelView: View {
    @ObservedObject var model: ScreenRecordingControlPanel.Model

    var body: some View {
        HStack(spacing: 10) {
            if let remaining = model.countdown {
                // 代码确实等了三秒，界面上却什么都不显示、只有一个 00:00 的
                // 红点，用户会以为已经在录了（复审二 P2）。显式画出 3/2/1。
                Text("\(remaining)")
                    .font(.system(.title2, design: .rounded).bold())
                    .monospacedDigit()
                    .foregroundStyle(.red)
                Text("Starting…").font(.caption)
            } else if model.isFinalizing {
                ProgressView().controlSize(.small)
                Text("Finalizing…").font(.caption)
            } else {
                Circle()
                    .fill(.red)
                    .frame(width: 9, height: 9)
                    // 呼吸感只是视觉，不承载状态
                    .opacity(0.9)
                Text(MediaFormatting.duration(model.elapsed))
                    .font(.system(.callout, design: .monospaced))
                    .monospacedDigit()
            }

            Spacer(minLength: 4)

            Button {
                model.onStop()
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(model.isFinalizing)
            .instantHelp("Stop recording and finish writing the file")
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .overlay(alignment: .bottom) {
            if let warning = model.warning {
                Text(warning)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(.bottom, 2)
            }
        }
    }
}
