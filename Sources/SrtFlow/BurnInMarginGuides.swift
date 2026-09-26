import SwiftUI
import SrtFlowCore

// 管什么：烧字幕页预览上的边距参考线（左右两条竖线是换行的位置，一条横线是到边缘的距离）和线上的数字标签。
// 不管什么：什么时候显示（`MarginGuideFlash`，调边距时闪一下）、字幕本身怎么画（`BurnInSubtitleOverlay`）。
// 2026-09-26 从 BurnInPreviewArea.swift 拆出来（那个文件在行数基线里只许降，见 docs/architecture/coding-standards.md）。

// MARK: - 边距参考线

/// 边距参考线：两条竖线是左右边距（也就是长句换行的位置），一条横线是到边缘的距离。
struct MarginGuideOverlay: View {
    let style: BurnInStyle
    let scale: Double
    let boxSize: CGSize

    private var sideInset: Double { Double(style.marginHorizontal) * scale }
    private var edgeInset: Double { Double(style.marginVertical) * scale }

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        ZStack(alignment: .topLeading) {
            verticalGuide(at: sideInset, label: "\(style.marginHorizontal)", labelOnRight: true)
            verticalGuide(at: boxSize.width - sideInset, label: "\(style.marginHorizontal)", labelOnRight: false)
            if !style.position.isVerticallyCentered {
                horizontalGuide(
                    at: style.position.row == 0 ? boxSize.height - edgeInset : edgeInset,
                    label: "\(style.marginVertical)"
                )
            }
        }
        .frame(width: boxSize.width, height: boxSize.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func verticalGuide(at x: Double, label: String, labelOnRight: Bool) -> some View {
        let clamped = min(max(0, x), boxSize.width)
        return ZStack(alignment: labelOnRight ? .topLeading : .topTrailing) {
            Rectangle()
                .fill(Color.accentColor.opacity(0.9))
                .frame(width: 1, height: boxSize.height)
            GuideLabel(text: label)
                .padding(.horizontal, 4)
                .padding(.top, 4)
        }
        .frame(width: 60, alignment: labelOnRight ? .leading : .trailing)
        .offset(x: labelOnRight ? clamped : clamped - 60)
    }

    private func horizontalGuide(at y: Double, label: String) -> some View {
        let clamped = min(max(0, y), boxSize.height)
        return ZStack(alignment: .bottomLeading) {
            Rectangle()
                .fill(Color.accentColor.opacity(0.9))
                .frame(width: boxSize.width, height: 1)
            GuideLabel(text: label)
                .padding(.leading, 6)
                .padding(.bottom, 3)
        }
        .frame(width: boxSize.width, height: 20, alignment: .bottomLeading)
        .offset(y: clamped - 20)
    }
}

private struct GuideLabel: View {
    let text: String

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        Text(text)
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Color.accentColor.opacity(0.85), in: RoundedRectangle(cornerRadius: 3))
    }
}
