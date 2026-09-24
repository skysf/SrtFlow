import SwiftUI

// MARK: - 拖文字块换行时的目标指示
//
// 管什么：目标行怎么画 —— 已有行描一圈（和跨轨拖动的目标轨同一种描边），最上面那行
// 之上画一条插入线（顶上新开一行，和插入缝那条线同款）。
// 不管什么：目标行怎么判（`TextRows.dropTarget`）、松手落地（`TimelineState.settleTextRow`）。

struct TextRowDropIndicator: View {
    /// `textDropRow`：nil = 没在换行；等于行数 = 顶上新开一行。
    let row: Int?
    let layouts: [VideoEditTimelineView.RowLayout]
    let width: Double

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        if let row {
            if let layout = layouts.first(where: { $0.spec.textRow == row }) {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.teal, lineWidth: 2)
                    .frame(width: width, height: layout.spec.height)
                    .offset(y: layout.minY)
                    .allowsHitTesting(false)
            } else if let top = layouts.first(where: { $0.spec.textRow != nil }) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.teal)
                    .frame(width: width, height: 3)
                    .offset(y: top.minY - 2)
                    .allowsHitTesting(false)
            }
        }
    }
}
