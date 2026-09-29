import Foundation
import SrtFlowCore

// 盖一块在成片里的各条断言（场景搭法见 main.swift 的说明）。

// MARK: - 纯值：几何、力度换算、清单、存盘

func runPureChecks() {
    let size = CGSize(width: 320, height: 180)
    var cover = ShapeAnnotation(kind: .blur, timelineStart: 0, duration: 2, centerX: 0.5, centerY: 0.5, width: 0.5, height: 0.5)
    // 45…135 取偶数往外收成 44…136：yuv420 的 crop / overlay 要偶数对齐，不取偶数 overlay 会错一个像素。
    check(VideoEditCoverExport.pixelRect(cover, canvas: size) == CGRect(x: 80, y: 44, width: 160, height: 92),
          "盖一块的像素框取偶数（往外收）")
    // x 105.6…214.4：取偶数往外收成 104…216（不取偶数的话 crop 和 overlay 各按自己的取整，overlay 错一个像素）。
    var odd = ShapeAnnotation(kind: .blur, timelineStart: 0, duration: 2, centerX: 0.5, centerY: 0.5, width: 0.34, height: 0.5)
    check(VideoEditCoverExport.pixelRect(odd, canvas: size) == CGRect(x: 104, y: 44, width: 112, height: 92), "x 也取偶数往外收")
    odd.width = 0.5
    cover.centerX = 0.02
    cover.width = 0.2
    check(VideoEditCoverExport.pixelRect(cover, canvas: size) == CGRect(x: 0, y: 44, width: 40, height: 92),
          "探出画布的收进画布")
    cover.centerX = 1.5
    check(VideoEditCoverExport.pixelRect(cover, canvas: size) == nil, "整个在画布外的不导出")
    check(abs(VideoEditCoverExport.pixels(28, canvas: CGSize(width: 1920, height: 1080)) - 28) < 1e-9, "1080p 上力度就是像素")
    check(abs(VideoEditCoverExport.pixels(54, canvas: size) - 9) < 1e-9, "力度按成片画布的高换算（180 高：54 → 9 像素）")
    check(abs(VideoEditCoverExport.pixels(28, canvas: CGSize(width: 1080, height: 1920)) - 28 * 1920 / 1080) < 1e-9,
          "竖屏按高换算：画面高 1920，力度 28 → 49.8 像素")

    var state = TimelineState()
    let clip = EditClip(sourceURL: URL(fileURLWithPath: "/tmp/x.mp4"), sourceDuration: 4, timelineStart: 0, info: info(seconds: 4))
    state.mainClips = [clip]
    let box = ShapeAnnotation(kind: .rectangle, timelineStart: 0, duration: 2)
    var blur = ShapeAnnotation(kind: .blur, timelineStart: 1, duration: 10)
    var hidden = ShapeAnnotation(kind: .mosaic, timelineStart: 0, duration: 2)
    hidden.isHidden = true
    state.shapes = [box, blur, hidden]
    check(state.renderedShapes.map(\.id) == [box.id], "盖一块不进 renderedShapes（那是画出来的）")
    check(state.renderedCovers.map(\.id) == [blur.id], "renderedCovers 只有没藏的盖一块")
    check(abs(state.duration - 4) < 1e-9, "盖一块不算总长（盖在空白上没有意义；长到 11 秒也不把工程撑长）")
    state.shapes = [box]

    blur.coverAmount = 40
    guard let data = try? JSONEncoder().encode(blur), let text = String(data: data, encoding: .utf8) else {
        check(false, "盖一块编不了码")
        return
    }
    check(text.contains("\"coverAmount\":40"), "盖一块落 coverAmount 的键")
    check(!((try? String(data: JSONEncoder().encode(box), encoding: .utf8))?.contains("coverAmount") ?? true), "别的形状不落 coverAmount")
    check((try? JSONDecoder().decode(ShapeAnnotation.self, from: data))?.coverAmount == 40, "往返不丢力度")
    let old = "{\"kind\":\"mosaic\",\"timelineStart\":0,\"duration\":2}"
    check((try? JSONDecoder().decode(ShapeAnnotation.self, from: Data(old.utf8)))?.coverAmount == ShapeKind.mosaic.defaultCoverAmount,
          "缺键 = 这个种类的默认力度")
    let future = "{\"kind\":\"sparkle\",\"timelineStart\":0,\"duration\":2}"
    check((try? JSONDecoder().decode(ShapeAnnotation.self, from: Data(future.utf8)))?.kind == .rectangle, "不认识的种类宽容回落成长方形")
}

// MARK: - 真导出

private func clipState(_ url: URL, seconds: Double = 4) -> TimelineState {
    var state = TimelineState()
    state.mainClips = [EditClip(sourceURL: url, sourceDuration: seconds, timelineStart: 0, info: info(seconds: seconds))]
    return state
}

/// 画布正中 160 × 72（x 80…240、y 54…126，四边都是偶数）的一块盖一块。
private func cover(_ kind: ShapeKind, amount: Double, start: Double = 1, duration: Double = 2, height: Double = 0.4) -> ShapeAnnotation {
    ShapeAnnotation(kind: kind, timelineStart: start, duration: duration, centerX: 0.5, centerY: 0.5, width: 0.5, height: height, coverAmount: amount)
}

/// 标准正态的分布函数，理想的高斯阶跃响应用。
private func normalCDF(_ z: Double) -> Double { 0.5 * (1 + erf(z / 2.0.squareRoot())) }

func runExportChecks(redBlue: URL, checker: URL) async {
    // ---- 1. 模糊：块外和基线一致、块内是高斯剖面、上下边界是那一块的边界
    do {
        let base = clipState(redBlue)
        var covered = base
        covered.shapes = [cover(.blur, amount: 54)]   // 高斯半径 54 × 180 / 1080 = 9 像素
        if let baseline = await export(base, name: "blur-base.mp4"), let product = await export(covered, name: "blur.mp4"),
           let fb = frame(baseline, at: 2, name: "blur-base"), let fc = frame(product, at: 2, name: "blur") {
            for (x, y) in [(20, 20), (300, 160), (160, 20), (160, 160), (60, 90), (260, 90)] {
                check(fc.difference(fb, x: x, y: y) <= 12, "块外 (\(x),\(y)) 和基线一致，差 \(fc.difference(fb, x: x, y: y))")
            }
            check(fc.pixel(159, 20).r - fc.pixel(160, 20).r > 120, "块的上方，红蓝的交界还是硬的（没被糊到）")
            let left = fb.pixel(20, 90).r, right = fb.pixel(300, 90).r
            for x in [136, 145, 151, 160, 169, 175, 184] {
                // 高斯半径 9：交界在 160，像素 x 的中心在 x + 0.5
                let ideal = Double(right) + Double(left - right) * (1 - normalCDF((Double(x) + 0.5 - 160) / 9))
                let got = Double(fc.pixel(x, 90).r)
                check(abs(got - ideal) <= 30, "块内 x=\(x) 的红通道贴着理想的高斯剖面：实测 \(got)，理想 \(Int(ideal))")
            }
            let profile = stride(from: 120, through: 200, by: 8).map { fc.pixel($0, 90).r }
            check(zip(profile, profile.dropFirst()).allSatisfy { $1 <= $0 + 4 }, "剖面单调下降（不是台阶、不抖）：\(profile)")
        }
    }

    // ---- 2. 改动的外接框就是那一块（棋盘素材：块内每个像素都会被糊成灰）
    do {
        let base = clipState(checker)
        var covered = base
        covered.shapes = [cover(.blur, amount: 54)]
        if let baseline = await export(base, name: "geo-base.mp4"), let product = await export(covered, name: "geo.mp4"),
           let fb = frame(baseline, at: 2, name: "geo-base"), let fc = frame(product, at: 2, name: "geo"),
           let box = fc.changedBounds(from: fb, threshold: 30) {
            check(abs(box.x0 - 80) <= 2 && abs(box.y0 - 54) <= 2 && abs(box.x1 - 240) <= 2 && abs(box.y1 - 126) <= 2,
                  "改动的外接框是那一块 (80,54)–(240,126)，实测 (\(box.x0),\(box.y0))–(\(box.x1),\(box.y1))")
            for (x, y) in [(70, 90), (250, 90), (160, 45), (160, 135), (79, 54), (240, 125)] {
                check(fc.difference(fb, x: x, y: y) <= 30, "块边外一格 (\(x),\(y)) 没被改")
            }
        } else {
            check(false, "棋盘上没有找到被改的像素：盖一块没盖上")
        }
    }

    // ---- 3. 马赛克：格子边长对、格子从这一块的左上角起算
    do {
        guard let noise = makeVideo("noise.mp4", graph: "nullsrc=s=320x180:r=10:d=4,geq=lum='random(1)*219+16':cb=128:cr=128") else { return }
        let base = clipState(noise)
        var covered = base
        covered.shapes = [cover(.mosaic, amount: 48)]   // 48 × 180 / 1080 = 8 像素一格
        if let baseline = await export(base, name: "mosaic-base.mp4"), let product = await export(covered, name: "mosaic.mp4"),
           let fb = frame(baseline, at: 2, name: "mosaic-base"), let fc = frame(product, at: 2, name: "mosaic") {
            /// 一个 8×8 的格子里最亮和最暗差多少（灰度取 G 通道）。
            func spread(_ f: Frame, x0: Int, y0: Int) -> Int {
                let values = (0..<8).flatMap { dy in (0..<8).map { dx in f.pixel(x0 + dx, y0 + dy).g } }
                return (values.max() ?? 0) - (values.min() ?? 0)
            }
            // 只量块内部的格子：靠着块边的格子会被 h264 的宏块（16×16）切开、带上量化噪声，不代表格子对不对。
            for (i, j) in [(3, 2), (7, 4), (10, 5), (14, 3), (16, 6)] {
                let s = spread(fc, x0: 80 + 8 * i, y0: 54 + 8 * j)
                check(s <= 8, "马赛克的格子 (\(i),\(j)) 里是一个颜色，差 \(s)")
            }
            let shifted = [(3, 2), (7, 4), (10, 5), (14, 3), (16, 6)].map { spread(fc, x0: 84 + 8 * $0.0, y0: 58 + 8 * $0.1) }
            check(shifted.contains { $0 > 8 }, "错开半格量就不是一个颜色（格子从这一块的左上角起算）：\(shifted)")
            check(spread(fc, x0: 20, y0: 20) > 60, "块外还是噪声（没被打码）：差 \(spread(fc, x0: 20, y0: 20))")
            // 噪声素材两次编码本身就有差（外接框的断言在棋盘那一组里做），这里只看块外的几点大体一致。
            let outside = [(20, 20), (300, 170), (40, 90), (280, 90)].map { fc.difference(fb, x: $0.0, y: $0.1) }
            check(outside.filter { $0 > 60 }.count <= 1, "块外和基线大体一致：\(outside)")
        }
    }

    // ---- 4. 只在那一段时间里盖
    do {
        let base = clipState(checker)
        var covered = base
        covered.shapes = [cover(.blur, amount: 54, start: 1, duration: 2)]   // 1…3 秒
        if let baseline = await export(base, name: "time-base.mp4"), let product = await export(covered, name: "time.mp4") {
            for (t, expectChanged) in [(0.5, false), (1.5, true), (2.5, true), (3.5, false)] {
                if let fb = frame(baseline, at: t, name: "time-base"), let fc = frame(product, at: t, name: "time") {
                    let changed = fc.changedBounds(from: fb, threshold: 40) != nil
                    check(changed == expectChanged, "\(t) 秒\(expectChanged ? "在" : "不在")盖一块的时间里：\(changed ? "改了" : "没改")")
                }
            }
        }
    }

    // ---- 5. 层序：形状盖在盖一块上面、不被糊；调色在盖一块前面
    do {
        var state = clipState(checker)
        var shape = ShapeAnnotation(kind: .rectangle, timelineStart: 0, duration: 4, color: .black, centerX: 0.5, centerY: 0.5, width: 0.2, height: 0.2)
        shape.isFilled = true
        state.shapes = [shape]
        let base = state
        state.shapes.append(cover(.blur, amount: 54))
        state.filters = [FilterClip(preset: .coldIron, strength: 1, timelineStart: 0, duration: 4, layer: 0)]
        if let graph = await filterGraph(state, name: "order") {
            let grade = graph.range(of: "lut3d")?.lowerBound, blur = graph.range(of: "gblur")?.lowerBound
            let overlay = graph.range(of: "overlay=x=0:y=0:eof_action=pass")?.lowerBound
            check(grade != nil && blur != nil && overlay != nil, "滤镜图里有调色、模糊、形状叠加三样")
            if let grade, let blur, let overlay {
                check(grade < blur, "调色在盖一块前面（盖的是调完色的画面）")
                check(blur < overlay, "盖一块在形状叠加前面（形状压在它上面）")
            }
        }
        state.filters = []
        if let baseline = await export(base, name: "layer-base.mp4"), let product = await export(state, name: "layer.mp4"),
           let fb = frame(baseline, at: 2, name: "layer-base"), let fc = frame(product, at: 2, name: "layer") {
            // 量形状边缘里面 4 像素的地方（形状 x 128…192）：形状要是被糊了，这里会被外面的棋盘灰拽亮；正中心离边缘远，糊不到。
            check(fc.pixel(132, 90).g < 40, "盖在模糊块上面的形状还是实心的黑，不是糊成灰的：\(fc.pixel(132, 90))")
            check(fc.difference(fb, x: 132, y: 90) <= 20 && fc.difference(fb, x: 160, y: 90) <= 20, "形状里面和基线一致")
            check(fc.difference(fb, x: 100, y: 90) > 40, "形状外面、块里面被糊了")
        }
    }

    // ---- 6. 藏起来的不导出；力度决定滤镜参数
    do {
        var state = clipState(redBlue)
        var hidden = cover(.blur, amount: 54)
        hidden.isHidden = true
        state.shapes = [hidden]
        if let graph = await filterGraph(state, name: "hidden") {
            check(!graph.contains("gblur") && !graph.contains("pixelize"), "藏起来的盖一块不进成片")
        }
        state.shapes = [cover(.blur, amount: 54), cover(.mosaic, amount: 48, start: 0)]
        if let graph = await filterGraph(state, name: "params") {
            check(graph.contains("gblur=sigma=9:steps=\(VideoEditCoverExport.gaussianSteps)"), "模糊：高斯半径 = 力度 × 画布高 / 1080")
            check(graph.contains("pixelize=w=8:h=8:mode=avg"), "马赛克：格子边长 = 力度 × 画布高 / 1080")
        }
    }

    // ---- 7. 不算总长：盖一块长到 10 秒，成片还是 4 秒
    do {
        var state = clipState(redBlue)
        state.shapes = [cover(.blur, amount: 54, start: 0, duration: 10)]
        if let product = await export(state, name: "long.mp4"), let seconds = mediaDuration(product) {
            check(abs(seconds - 4) < 0.3, "盖一块不把成片撑长：\(seconds) 秒")
        }
    }
}
