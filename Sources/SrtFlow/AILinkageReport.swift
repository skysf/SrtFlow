import Foundation
import SrtFlowMCPKit

// MARK: - 联动的结果怎么报给 AI
//
// 管什么：一次改动之后联动（docs/architecture/timeline-linkage.md）挪了几样、删了几样，在工具结果里带一笔 `linkage`：
// AI 看得见「删了一段，它上面的三句字幕也没了、后面的两段文字跟着前移了」，不用再 get_timeline 对一遍。
// 什么都没动就不带（开关关着、或者这次没碰主轨的画面）。
// 不管什么：联动本身（`TimelineLinkage`）、开关（`get_timeline` 的 `linkage` 字段报着）。

enum AILinkageReport {
    static func json(_ report: TimelineLinkage.Report) -> JSONValue? {
        guard !report.isEmpty else { return nil }
        var entry: [String: JSONValue] = [:]
        if report.moved > 0 { entry["moved"] = .number(Double(report.moved)) }
        if report.deleted > 0 { entry["deleted"] = .number(Double(report.deleted)) }
        entry["note"] = .string("Linkage is on: items on other tracks followed the V1 clips they sit on.")
        return .object(entry)
    }
}
