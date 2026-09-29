import CoreGraphics
import Foundation
import SrtFlowMCPKit

// MARK: - 给一帧写几句话（「看」的文字那一半）
//
// 管什么：Vision 认出来的东西 + 亮度 + 黑边 → 一小段 JSON。看不了图的模型（DeepSeek 之类）全靠它挑镜头；
// 看得了图的模型也用得上：位置是量出来的准数，画面上的字是认出来的原文。纯值，自检够得着（scripts/check-mcp.sh）。
// 不管什么：怎么认（AIVision）、怎么量黑边（AIBlackBars）、帧从哪来。
//
// 省 token：没有的东西不写（没脸就没有 faces），位置保留两位小数，坐标一律是这一帧上的归一化值、左上原点。

enum AIFrameDescription {
    struct Input {
        var time: Double
        var luma: AIBlackBars.Luma?
        var vision: AIVision.Findings
    }

    static let maxFaces = 5
    static let maxTexts = 6

    static func describe(_ input: Input) -> JSONValue {
        var object: [String: JSONValue] = ["time": AIFormat.seconds(input.time)]
        let vision = input.vision
        if !vision.labels.isEmpty {
            object["shows"] = .array(vision.labels.map { .string($0.name) })
        }
        let faces = vision.subject.faces
            .sorted { $0.width * $0.height > $1.width * $1.height }
            .prefix(maxFaces)
        if !faces.isEmpty {
            object["faces"] = .array(faces.map(box))
        }
        if !vision.subject.people.isEmpty {
            object["people"] = .number(Double(vision.subject.people.count))
        }
        if let aim = AISubjectFocus.focus(in: vision.subject, window: CGSize(width: 1, height: 1)) {
            object["subject"] = [
                "kind": .string(aim.kind.rawValue), "x": rounded(aim.point.x), "y": rounded(aim.point.y)
            ]
        }
        if !vision.texts.isEmpty {
            // 字连同它在哪（[x, y, 宽, 高]）：AI 挪字幕、按字取景、找水印都要位置。最多写 6 块。
            object["text"] = .array(vision.texts.prefix(maxTexts).map { ["text": .string($0.string), "box": box($0.box)] })
        }
        if let luma = input.luma {
            object["brightness"] = rounded(brightness(luma))
            if let bars = AIBlackBars.bars(in: luma), !bars.isEmpty {
                object["black_bars"] = AIBlackBars.json(bars)
            }
        }
        return .object(object)
    }

    /// 平均亮度 0…1。
    static func brightness(_ luma: AIBlackBars.Luma) -> Double {
        guard !luma.pixels.isEmpty else { return 0 }
        let total = luma.pixels.reduce(0) { $0 + Int($1) }
        return Double(total) / Double(luma.pixels.count) / 255
    }

    /// [x, y, 宽, 高]，两位小数。
    static func box(_ rect: CGRect) -> JSONValue {
        .array([rounded(rect.minX), rounded(rect.minY), rounded(rect.width), rounded(rect.height)])
    }

    private static func rounded(_ value: Double) -> JSONValue {
        .number((value * 100).rounded() / 100)
    }
}
