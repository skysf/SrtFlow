import Foundation
import SrtFlowMCPKit

// MARK: - fal 的账单明细：一次请求实际扣了多少（纯值）
//
// 管什么：平台接口 `GET https://api.fal.ai/v1/models/billing-events` 的查询参数和答复的形状。每个请求做完几分钟内会出现一条
// 带 `request_id` 的事件，`cost_total` 就是实际扣的钱 —— upscale 的对比窗口用它把「估价」换成「实际」。
// 要 **ADMIN 权限的 Key**：只有 API 权限的 Key 会被拒（401 / 403），调用方当作查不到，照旧只显示估价。
// 不管什么：发请求（FalClient.billingEvents）、什么时候查、查几次。

struct FalBillingEvent: Equatable, Sendable {
    var requestID: String
    var endpoint: String
    /// fal 记的用量（单位看端点：秒、unit……）。
    var units: Double
    var unitPrice: Double
    /// 折扣之后实际扣的美元数。
    var cost: Double
}

enum FalBilling {
    static let path = "v1/models/billing-events"

    /// 查询参数：从什么时候起、哪几个请求（接口收重复的 `request_id`）。
    static func query(requestIDs: [String], since: Date) -> [URLQueryItem] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        var items = [URLQueryItem(name: "start", value: formatter.string(from: since)), URLQueryItem(name: "limit", value: "200")]
        items += requestIDs.map { URLQueryItem(name: "request_id", value: $0) }
        return items
    }

    /// 答复里的事件（读得宽：缺字段的那条跳过，不整份丢掉）。
    static func events(from answer: JSONValue) -> [FalBillingEvent] {
        (answer["billing_events"]?.arrayValue ?? []).compactMap { item in
            guard let id = item["request_id"]?.stringValue, let endpoint = item["endpoint_id"]?.stringValue,
                  let cost = item["cost_total"]?.doubleValue else { return nil }
            return FalBillingEvent(
                requestID: id, endpoint: endpoint, units: item["output_units"]?.doubleValue ?? item["quantity"]?.doubleValue ?? 0,
                unitPrice: item["unit_price"]?.doubleValue ?? 0, cost: cost
            )
        }
    }

    static func cost(of requestID: String, in events: [FalBillingEvent]) -> Double? {
        let matching = events.filter { $0.requestID == requestID }
        guard !matching.isEmpty else { return nil }
        return matching.reduce(0) { $0 + $1.cost }
    }
}
