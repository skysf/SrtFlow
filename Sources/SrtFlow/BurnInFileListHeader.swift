import SwiftUI

// MARK: - 烧录页素材条的标题行
//
// 管什么：「Videos and subtitles」+ 空着时的两句提示 + 「Add Files…」这一行。
// 不管什么：文件列表本身、拖放（BurnInView）。
//
// 两句提示按**放不放得下**决定显示几句（`ViewThatFits`）：窗口默认 1180 宽时这一行放不下两句，
// 以前是把两句各截成「Drop a video and its subtitle fi…」（英文和西班牙语一样，
// docs/plans/2026-09-30-ui-languages.md 第六节），截断的提示不如少一句。
struct BurnInFileListHeader: View {
    let isEmpty: Bool
    let chooseFiles: () -> Void

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        HStack(spacing: 8) {
            Text("Videos and subtitles").font(.headline)
            if isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { dropHint; pairingHint }
                    dropHint
                    Color.clear.frame(width: 0, height: 0)
                }
            }
            Spacer()
            Button("Add Files…", action: chooseFiles)
                .instantHelp("Pick videos to burn subtitles into")
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // `fixedSize`：候选项不许自己缩，ViewThatFits 才量得出「放不放得下」。
    private var dropHint: some View {
        Text("Drop a video and its subtitle file here.")
            .font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
    }

    private var pairingHint: some View {
        Text("Files with matching names are paired automatically.")
            .font(.caption).foregroundStyle(.tertiary).lineLimit(1).fixedSize()
    }
}
