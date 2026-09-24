import SwiftUI

// MARK: - 波形（Logic 式）
//
// 从 `VideoEditTimelineView.swift` 拆出来（拆分前 2101 行，远超仓库约 800 行的
// 警戒线）。纯装饰，不吃事件（接线守卫 `checks/timeline-drag-wiring.sh` 第 8 节），
// 挪动这里的东西要同步改那份守卫。
//
// 2026-09-23 起换成 Logic 那种样子（长期约束见 docs/architecture/audio-waveform.md）：
//
// - 以中线**上下对称**的连续填充，上沿是每一列的最大值、下沿是最小值（真实的
//   min/max，不是柱子）；放得很大时每个桶一个顶点，连成一条起伏的线。
// - 数据按**文件**读一次，存多级峰值（`WaveformStore`），缩放只是换一级取。
// - 波形区够高（≥ `stereoSplitHeight`）时立体声拆成 L / R 两条。
// - 画的仍是**听到的声音**：段音量 / 音量曲线、渐入渐出、轨道推子都乘进去；
//   乘完超过 0 dBFS 的列涂红 —— 不播放也看得出哪儿会爆。
// - **只画 `context.clipBoundingRect` 那一段**：块在放大后能有几百万点宽，Canvas 只
//   光栅化可见条带、却每滚 128pt 把闭包整宽重跑一次，整宽画就是滚一下卡一下、内存
//   只涨不退（2026-09-23 探针：10M 宽时一次 370ms、内存 270→1080MB）。

/// 音频块里的波形 / 视频块底部的那条波形带。
struct WaveformView: View {
    let clip: EditClip
    let pps: Double
    /// 这段所在那条轨的推子（线性）。乘进波形：推子也是「听到的」一部分。
    let trackGain: Double

    @Environment(\.displayScale) private var displayScale
    @State private var peaks: WaveformPeaks?
    /// 深度放大时的原始采样块读到了一块就 +1，让 Canvas 重画一次
    /// （块本身在 `WaveformDetailCache` 里，绘制闭包同步去取）。
    @State private var detailRevision = 0

    /// 波形区高于这个值才把立体声拆成两条（默认 34pt 的音频行拆开就是两条细线）。
    static let stereoSplitHeight = 40.0

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        Canvas { [detailRevision] context, size in
            PerfCounters.canvas(Self.self)
            _ = detailRevision
            guard let peaks, peaks.sampleRate > 0, pps > 0 else { return }
            WaveformPainter(
                clip: clip, pps: pps, trackGain: trackGain, peaks: peaks,
                pixel: 1 / max(1, displayScale)
            ).draw(in: &context, size: size)
        }
        // 数据按文件取：裁切、分割、挪位置、缩放都不重读 PCM，只有换素材才重新订阅。
        .task(id: clip.sourceURL) {
            for await snapshot in await WaveformStore.shared.peaks(for: clip.sourceURL) {
                guard !Task.isCancelled else { return }
                peaks = snapshot
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: WaveformDetailCache.didLoad)) { note in
            guard (note.object as? URL) == clip.sourceURL.standardizedFileURL else { return }
            detailRevision &+= 1
        }
        // 与缩略图条同一条合同：块内装饰不吃事件（守卫在 timeline-drag-wiring）。
        .allowsHitTesting(false)
    }
}

/// 一次绘制。纯计算 + 画，拆出来让 `WaveformView` 只剩接线。
struct WaveformPainter {
    let clip: EditClip
    let pps: Double
    let trackGain: Double
    let peaks: WaveformPeaks
    /// 一个物理像素是多少点（Retina 上 0.5）。
    let pixel: Double

    /// 一列（或放大后的一个桶）的峰值与此刻的增益。
    struct Column {
        var x: Double
        var low: Float
        var high: Float
        var gain: Double
    }

    static let fill = Color.white.opacity(0.72)
    static let clipped = Color(red: 1, green: 0.27, blue: 0.23)

    func draw(in context: inout GraphicsContext, size: CGSize) {
        // 只画看得见的那一段（±4pt 余量，免得边缘那一列半截）。
        let visible = context.clipBoundingRect
        let x0 = max(0, visible.minX - 4)
        let x1 = min(Double(size.width), visible.maxX + 4)
        guard x1 > x0, size.height > 1 else { return }

        let lanes: [(channel: Int?, rect: CGRect)]
        if peaks.channelCount >= 2, size.height >= WaveformView.stereoSplitHeight {
            let half = size.height / 2
            lanes = [
                (0, CGRect(x: 0, y: 0, width: size.width, height: half)),
                (1, CGRect(x: 0, y: half, width: size.width, height: half)),
            ]
        } else {
            lanes = [(nil, CGRect(origin: .zero, size: size))]
        }
        for lane in lanes {
            let cols = columns(channel: lane.channel, from: x0, to: x1)
            guard cols.count >= 2 else { continue }
            drawLane(cols, in: lane.rect, context: &context)
        }
    }

    // MARK: 取数

    /// 离段起点 `x` 点处对应的源采样帧。
    private func frame(atX x: Double) -> Double {
        clip.sourceTime(atTimeline: clip.timelineStart + x / pps) * peaks.sampleRate
    }

    private func x(atFrame frame: Double) -> Double {
        (clip.timelineTime(atSource: frame / peaks.sampleRate) - clip.timelineStart) * pps
    }

    private func gain(atX x: Double) -> Double {
        clip.heardGain(atTimeline: clip.timelineStart + x / pps, trackGain: trackGain)
    }

    /// 可见范围里的列，每个物理像素一列。一个像素盖得住一个桶时从多级峰值里取；
    /// 放大到一个像素还盖不满一个桶时改读原始采样（见下面那一支）。
    private func columns(channel: Int?, from x0: Double, to x1: Double) -> [Column] {
        let limit = Double(peaks.framesAvailable)
        let windowStart = clip.sourceStart * peaks.sampleRate
        let windowEnd = min(limit, (clip.sourceStart + clip.sourceDuration) * peaks.sampleRate)
        let framesPerPixel = abs(frame(atX: x0 + pixel) - frame(atX: x0))
        var result: [Column] = []

        if framesPerPixel >= Double(WaveformPeaks.baseBucket) {
            let level = WaveformPeaks.level(forFramesPerPixel: framesPerPixel)
            var x = (x0 / pixel).rounded(.down) * pixel
            while x < x1 {
                let from = max(windowStart, frame(atX: x))
                let to = min(windowEnd, frame(atX: x + pixel))
                if to > from,
                   let range = peaks.extremes(channel: channel, from: Int(from), to: max(Int(to), Int(from) + 1),
                                              level: level) {
                    result.append(Column(x: x + pixel / 2, low: range.min, high: range.max,
                                         gain: gain(atX: x + pixel / 2)))
                }
                x += pixel
            }
        } else {
            // 一个像素还盖不满一个桶：改读**原始采样**（只读看得见的那一两秒，1 秒一块），
            // 每个像素取真实采样的 min/max —— 正弦画出来就是一条正弦。块还没读到的
            // 地方先拿 64 采样的桶顶着（`WaveformDetailCache` 读完会发通知重画）。
            let detail = WaveformDetailCache.shared
            let tileFrames = Int(WaveformDetailCache.tileSeconds * peaks.sampleRate)
            let firstTile = Int(max(0, max(windowStart, frame(atX: x0))) / Double(tileFrames))
            let lastTile = Int(max(0, min(windowEnd, frame(atX: x1))) / Double(tileFrames))
            if lastTile >= firstTile {
                detail.request(url: clip.sourceURL, indices: firstTile...lastTile,
                               sampleRate: peaks.sampleRate, channels: peaks.channelCount)
            }
            var cachedIndex = -1
            var cachedTile: WaveformDetailTile?
            var x = (x0 / pixel).rounded(.down) * pixel
            while x < x1 {
                let from = max(windowStart, frame(atX: x))
                let to = min(windowEnd, frame(atX: x + pixel))
                if to > from {
                    let start = Int(from)
                    let end = max(Int(to), start + 1)
                    let index = start / max(1, tileFrames)
                    if index != cachedIndex {
                        cachedIndex = index
                        cachedTile = detail.tile(url: clip.sourceURL, index: index)
                    }
                    let range = cachedTile?.extremes(channel: channel, from: start, to: end)
                        ?? peaks.extremes(channel: channel, from: start, to: end, level: 0)
                    if let range {
                        result.append(Column(x: x + pixel / 2, low: range.min, high: range.max,
                                             gain: gain(atX: x + pixel / 2)))
                    }
                }
                x += pixel
            }
        }
        return result
    }

    // MARK: 画

    /// 波形的纵向刻度：幅度开 0.7 次方再画（小信号抬一点，看得见形状；满幅仍是满幅），
    /// 超过满幅的夹在边上 —— 那一列另外涂红。
    private static func shaped(_ value: Double) -> Double {
        let magnitude = min(1, abs(value))
        return (value < 0 ? -1 : 1) * pow(magnitude, 0.7)
    }

    private func drawLane(_ cols: [Column], in rect: CGRect, context: inout GraphicsContext) {
        let mid = rect.midY
        let half = rect.height / 2 - 0.5
        func top(_ c: Column) -> Double { mid - Self.shaped(Double(c.high) * c.gain) * half }
        func bottom(_ c: Column) -> Double { mid - Self.shaped(Double(c.low) * c.gain) * half }

        var shape = Path()
        shape.move(to: CGPoint(x: cols[0].x, y: top(cols[0])))
        for c in cols.dropFirst() { shape.addLine(to: CGPoint(x: c.x, y: top(c))) }
        for c in cols.reversed() { shape.addLine(to: CGPoint(x: c.x, y: max(bottom(c), top(c) + 0.5))) }
        shape.closeSubpath()
        context.fill(shape, with: .color(Self.fill))

        // 爆音：乘完增益超过 0 dBFS 的列，整列涂红（Final Cut 的做法）。
        var red = Path()
        let width = max(pixel, cols.count > 1 ? abs(cols[1].x - cols[0].x) : pixel)
        for c in cols where max(abs(Double(c.high)), abs(Double(c.low))) * c.gain > 1 {
            red.addRect(CGRect(x: c.x - width / 2, y: top(c), width: width, height: max(1, bottom(c) - top(c))))
        }
        if !red.isEmpty { context.fill(red, with: .color(Self.clipped)) }
    }
}
