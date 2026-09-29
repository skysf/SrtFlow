import Foundation
import SrtFlowMCPKit

// fal.ai 生成（第六块）自检的公共小件：计数、断言、读接口定义的快照并验请求体。编法见 scripts/check-fal.sh。

var failures = 0
var checks = 0

func check(_ condition: Bool, _ message: String, line: Int = #line, file: String = #fileID) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL [\(file):\(line)] \(message)")
    }
}

func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String, file: String = #fileID, line: Int = #line) {
    checks += 1
    if actual != expected {
        failures += 1
        print("FAIL [\(file):\(line)] \(message): got \(actual), expected \(expected)")
    }
}

func checkClose(_ actual: Double?, _ expected: Double, _ message: String, tolerance: Double = 1e-9, file: String = #fileID, line: Int = #line) {
    checks += 1
    guard let actual, abs(actual - expected) <= tolerance else {
        failures += 1
        print("FAIL [\(file):\(line)] \(message): got \(String(describing: actual)), expected \(expected)")
        return
    }
}

/// 这段代码应该抛错；没抛就记一条失败。
func checkThrows(_ message: String, file: String = #fileID, line: Int = #line, _ body: () throws -> Void) {
    checks += 1
    do {
        try body()
        failures += 1
        print("FAIL [\(file):\(line)] \(message): expected an error, got none")
    } catch {}
}

/// 抛的是 `FalInputError`，而且话里带着这几个词（AI 要看得懂）。
func checkInputError(_ message: String, contains words: [String], file: String = #fileID, line: Int = #line, _ body: () throws -> Void) {
    checks += 1
    do {
        try body()
        failures += 1
        print("FAIL [\(file):\(line)] \(message): expected a FalInputError, got none")
    } catch let error as FalInputError {
        let missing = words.filter { !error.message.lowercased().contains($0.lowercased()) }
        if !missing.isEmpty {
            failures += 1
            print("FAIL [\(file):\(line)] \(message): the error \"\(error.message)\" lacks \(missing)")
        }
    } catch {
        failures += 1
        print("FAIL [\(file):\(line)] \(message): expected a FalInputError, got \(error)")
    }
}

// MARK: - fal 公开的接口定义（checks/Fal/schemas/ 里的快照）

/// 一个端点的 OpenAPI 快照：拿它验我们造的请求体、我们写的样例输出。
struct FalSchema {
    let endpoint: String
    let spec: JSONValue

    static func snapshotURL(_ endpoint: String) -> URL {
        URL(fileURLWithPath: "checks/Fal/schemas/" + endpoint.replacingOccurrences(of: "/", with: "__") + ".json")
    }

    init?(endpoint: String) {
        guard let data = try? Data(contentsOf: Self.snapshotURL(endpoint)), let spec = try? JSONValue.decode(data) else { return nil }
        self.endpoint = endpoint
        self.spec = spec
    }

    /// 提交请求的那条路径（`POST /<端点号>`）。
    var submitPath: String? { spec["paths"]?.objectValue?.first { $0.value["post"] != nil }?.key }

    private func schema(at path: String, method: String, response: Bool) -> JSONValue? {
        guard let operation = spec["paths"]?[path]?[method] else { return nil }
        let content = response ? operation["responses"]?["200"]?["content"] : operation["requestBody"]?["content"]
        return content?["application/json"]?["schema"]
    }

    var input: JSONValue? { schema(at: "/" + endpoint, method: "post", response: false).map(resolve) }
    var output: JSONValue? { schema(at: "/" + endpoint + "/requests/{request_id}", method: "get", response: true).map(resolve) }

    func resolve(_ node: JSONValue) -> JSONValue {
        var current = node
        while let ref = current["$ref"]?.stringValue {
            var cursor: JSONValue? = spec
            for part in ref.split(separator: "/").dropFirst() { cursor = cursor?[String(part)] }
            guard let next = cursor else { return current }
            current = next
        }
        return current
    }

    // MARK: 验

    /// 一个值符不符合这份定义；返回问题列表（空 = 符合）。认：type / enum / 数值范围 / 字符串长度 / required / anyOf / items，
    /// 对象里**多出来的字段也算问题**（登记的端点我们该严格：多发的字段要么被忽略、要么被拒）。
    func problems(_ value: JSONValue, against node: JSONValue, path: String = "$") -> [String] {
        let schema = resolve(node)
        if let branches = schema["anyOf"]?.arrayValue {
            let tried = branches.map { problems(value, against: $0, path: path) }
            return tried.contains { $0.isEmpty } ? [] : ["\(path): matches none of the alternatives (\(tried.flatMap { $0 }.joined(separator: " | ")))"]
        }
        var found: [String] = []
        if let type = schema["type"]?.stringValue {
            let ok: Bool
            switch (type, value) {
            case ("null", .null), ("boolean", .bool), ("string", .string), ("array", .array), ("object", .object), ("number", .number): ok = true
            case ("integer", .number): ok = value.intValue != nil
            default: ok = false
            }
            if !ok { return ["\(path): expected \(type), got \(value.encodedString().prefix(40))"] }
        }
        if let allowed = schema["enum"]?.arrayValue, !allowed.contains(value) {
            found.append("\(path): \(value.encodedString()) is not one of \(allowed.map { $0.encodedString() }.joined(separator: ","))")
        }
        if case .number(let number) = value {
            if let low = schema["minimum"]?.doubleValue, number < low { found.append("\(path): \(number) < minimum \(low)") }
            if let high = schema["maximum"]?.doubleValue, number > high { found.append("\(path): \(number) > maximum \(high)") }
            if let low = schema["exclusiveMinimum"]?.doubleValue, number <= low { found.append("\(path): \(number) <= exclusiveMinimum \(low)") }
        }
        if case .string(let text) = value {
            if let low = schema["minLength"]?.intValue, text.count < low { found.append("\(path): shorter than minLength \(low)") }
            if let high = schema["maxLength"]?.intValue, text.count > high { found.append("\(path): longer than maxLength \(high)") }
        }
        if case .array(let items) = value, let itemSchema = schema["items"] {
            for (index, item) in items.enumerated() { found += problems(item, against: itemSchema, path: "\(path)[\(index)]") }
        }
        if case .object(let object) = value {
            let properties = schema["properties"]?.objectValue ?? [:]
            for name in schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where object[name] == nil {
                found.append("\(path): missing required field \(name)")
            }
            if !properties.isEmpty {
                for (name, inner) in object {
                    guard let definition = properties[name] else { found.append("\(path): unknown field \(name)"); continue }
                    found += problems(inner, against: definition, path: path + "." + name)
                }
            }
        }
        return found
    }

    func inputProblems(_ body: JSONValue) -> [String] {
        guard let input else { return ["no input schema in the snapshot of \(endpoint)"] }
        return problems(body, against: input)
    }

    func outputProblems(_ body: JSONValue) -> [String] {
        guard let output else { return ["no output schema in the snapshot of \(endpoint)"] }
        return problems(body, against: output)
    }
}

/// 造出来的请求体要符合这个端点的定义。
func checkValidInput(_ endpoint: String, _ body: JSONValue, _ message: String, file: String = #fileID, line: Int = #line) {
    guard let schema = FalSchema(endpoint: endpoint) else {
        check(false, "\(message): no schema snapshot for \(endpoint)", line: line, file: file)
        return
    }
    let problems = schema.inputProblems(body)
    check(problems.isEmpty, "\(message): \(problems.joined(separator: "; "))", line: line, file: file)
}

/// 一个样例输出要符合这个端点的输出定义（样例是我们自己写的，别写成定义里不存在的形状）。
func checkValidOutput(_ endpoint: String, _ body: JSONValue, _ message: String, file: String = #fileID, line: Int = #line) {
    guard let schema = FalSchema(endpoint: endpoint) else {
        check(false, "\(message): no schema snapshot for \(endpoint)", line: line, file: file)
        return
    }
    let problems = schema.outputProblems(body)
    check(problems.isEmpty, "\(message): \(problems.joined(separator: "; "))", line: line, file: file)
}
