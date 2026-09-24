import SwiftUI

/// 就地编辑一段文字：画面上双击、时间线上双击块、Add 之后自动进入，
/// **三个入口一套规则**。
///
/// ## 一次编辑 = 一步撤销
///
/// 走 `beginLiveEdit` / `liveApply` / `endLiveEdit` 这套：每敲一个键都从
/// 手势开始那份快照重新应用（`liveApply` 的语义就是"不叠加"），于是画面
/// 实时跟着变，而整段编辑只在撤销栈上留**一格**。逐键注册撤销的话，
/// ⌘Z 会一个字一个字地退，谁也受不了。
///
/// ## 提交时机
///
/// 与仓库其余输入框一致：**回车或失焦即提交**，没有单独的「取消」——
/// 改错了按 ⌘Z。视图消失（切工程、播放头走出这段文字）也当提交，
/// 否则 `liveEditSnapshot` 会一直挂着，下一次拖动会从一份陈旧的快照出发。
struct TextInlineEditor: View {
    @ObservedObject var project: VideoEditProject
    let overlayID: UUID

    @State private var draft: String = ""
    @State private var loaded = false
    @FocusState private var focused: Bool

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        HStack(spacing: 8) {
            TextField("Text", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .focused($focused)
                .onSubmit { finish() }
            Button("Done") { finish() }
                .controlSize(.small)
                .instantHelp("Finish editing this text", shortcut: .plain("Return"))
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 8, y: 2)
        .onAppear {
            draft = project.state.textOverlays.first { $0.id == overlayID }?.text ?? ""
            loaded = true
            project.beginLiveEdit()
            focused = true
        }
        .onChange(of: draft) { _, new in
            // onAppear 把 draft 从模型灌进来那一下也会触发，别把它当成一次编辑。
            guard loaded else { return }
            project.liveUpdateTextOverlay(overlayID) { $0.text = new }
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { finish() }
        }
        .onDisappear { finish() }
    }

    private func finish() {
        guard project.textEditingRequest == overlayID else { return }
        project.textEditingRequest = nil
        project.endLiveEdit(rebuildsPreview: false)
    }
}
