import Foundation

// MARK: - Kokoro 出错时说什么
//
// 管什么：SrtFlowKokoro 这个模块抛的错（替换 speech-swift 的 AudioModelError，那个类型在它的公共模块里，没搬过来）。
// 文字是英文：App 那一层原样转给 AI，AI 用用户的语言转述。

public enum KokoroError: Error, LocalizedError, Equatable {
    /// 模型目录里缺文件（没下载完、被删了）。
    case modelMissing(String)
    /// 这一个音色不在模型里。
    case unknownVoice(String)
    /// 推理出错。
    case inference(String)

    public var errorDescription: String? {
        switch self {
        case .modelMissing(let detail): return "SrtFlow's voice model is incomplete: \(detail)"
        case .unknownVoice(let name): return "There is no voice called \(name) in SrtFlow's voice model."
        case .inference(let detail): return "SrtFlow's voice model failed: \(detail)"
        }
    }
}
