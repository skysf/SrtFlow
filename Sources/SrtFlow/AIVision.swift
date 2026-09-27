import CoreGraphics
import Foundation
import Vision

// MARK: - 用 macOS 自带的 Vision 看一帧
//
// 管什么：一张 CGImage → 认出来的人脸、人（上半身）、显眼的东西、这是什么（标签）、画面上的字。
// 框一律换成**左上原点**的归一化值（Vision 给的是左下原点）。edit_clip 铺满时对准主体、look 给不能看图的
// 模型写文字描述，都从这里拿。
// 不管什么：拿这些结果干什么（AISubjectFocus、AIFrameDescription）、帧从哪来（AIFrameSampler / AIFrameComposer）。
//
// **Vision 的 `perform` 是同步的，会卡住调它的线程**，而且它在自己的队列上干活 —— 属于「等本进程里别的活」，
// 照 docs/architecture/blocking-media-reads.md 一律挪出 Swift 并发的线程池：在 `MediaReadQueue.analysis`
// 上跑，async 这边只是挂起等结果。

enum AIVision {
    struct Options: OptionSet, Sendable {
        let rawValue: Int
        static let subject = Options(rawValue: 1)
        static let labels = Options(rawValue: 2)
        static let text = Options(rawValue: 4)
    }

    struct Label: Equatable, Sendable {
        var name: String
        var confidence: Double
    }

    struct Findings: Sendable {
        var subject = AISubjectFocus.FrameFindings()
        var labels: [Label] = []
        var texts: [String] = []
    }

    /// 标签：Vision 的分类是一棵很宽的树（「动物」「鸟」「企鹅」都会有），只留够把握的前几个。
    static let labelConfidence = 0.3
    static let maxLabels = 6
    static let maxTexts = 6

    static func analyze(_ image: CGImage, _ options: Options) async -> Findings {
        await MediaReadQueue.run(on: MediaReadQueue.analysis) { perform(image, options) }
    }

    /// 同步地跑完所有要的请求。**只在 `MediaReadQueue.analysis` 上调。**
    private static func perform(_ image: CGImage, _ options: Options) -> Findings {
        let faces = VNDetectFaceRectanglesRequest()
        let people = VNDetectHumanRectanglesRequest()
        let salient = VNGenerateAttentionBasedSaliencyImageRequest()
        let classify = VNClassifyImageRequest()
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.automaticallyDetectsLanguage = true
        text.usesLanguageCorrection = true
        var requests: [VNRequest] = []
        if options.contains(.subject) { requests += [faces, people, salient] }
        if options.contains(.labels) { requests.append(classify) }
        if options.contains(.text) { requests.append(text) }
        guard !requests.isEmpty else { return Findings() }
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        try? handler.perform(requests)

        var findings = Findings()
        if options.contains(.subject) {
            findings.subject.faces = (faces.results ?? []).map { topLeft($0.boundingBox) }
            findings.subject.people = (people.results ?? []).map { topLeft($0.boundingBox) }
            findings.subject.salient = (salient.results?.first?.salientObjects ?? []).map { topLeft($0.boundingBox) }
        }
        if options.contains(.labels) {
            findings.labels = (classify.results ?? [])
                .filter { Double($0.confidence) >= labelConfidence }
                .sorted { $0.confidence > $1.confidence }
                .prefix(maxLabels)
                .map { Label(name: $0.identifier.replacingOccurrences(of: "_", with: " "), confidence: Double($0.confidence)) }
        }
        if options.contains(.text) {
            findings.texts = (text.results ?? [])
                .compactMap { $0.topCandidates(1).first }
                .filter { $0.confidence >= 0.5 && !$0.string.trimmingCharacters(in: .whitespaces).isEmpty }
                .prefix(maxTexts)
                .map(\.string)
        }
        return findings
    }

    /// Vision 的归一化框是左下原点，换成左上原点。
    static func topLeft(_ box: CGRect) -> CGRect {
        CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
    }
}
