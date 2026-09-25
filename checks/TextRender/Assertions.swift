import Foundation

// 这个自检的断言与计数。从 main.swift 拆出来（那个文件超过 600 行、只许降），
// 各组断言（main.swift、HitGeometry.swift）共用这一份计数，最后由 main 汇总。
// 失败行带上文件名：断言分在几个文件里，光有行号分不清是哪一个。

var failures = 0
var checks = 0

func check(_ condition: Bool, _ message: String, file: String = #fileID, line: Int = #line) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL [\(file):\(line)] \(message)")
    }
}

func checkEqual<T: Equatable>(
    _ value: T, _ expected: T, _ message: String, file: String = #fileID, line: Int = #line
) {
    check(value == expected, "\(message)（期望 \(expected)，实际 \(value)）", file: file, line: line)
}

func checkClose(
    _ value: Double, _ expected: Double, _ tolerance: Double, _ message: String,
    file: String = #fileID, line: Int = #line
) {
    check(abs(value - expected) <= tolerance,
          "\(message)（期望 \(expected) ±\(tolerance)，实际 \(value)）", file: file, line: line)
}
