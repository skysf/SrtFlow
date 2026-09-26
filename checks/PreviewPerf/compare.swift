import Foundation

// 预览性能 ratchet 的比对器（docs/architecture/preview-perf-ratchet.md）。
// 由 scripts/check-preview-perf.sh 编译调用；`--self-test` 跑内置用例（check-all 里）。
//
// 规则（用户 2026-09-24 拍板：只许降不许涨，要加开销得先在别处省回同样多）：
//
// 1. 每个场景跑两遍，**计数必须一模一样**；不一样就跑第三遍，三遍里要有两遍一模一样，
//    用那两遍的数，另一遍当受了干扰（写进汇总页）。三遍两两都不一样，说明测试本身不稳，
//    那是测试的问题，不许靠放宽基线绕过去。
//    为什么允许一遍出局：CI 虚拟机上偶尔有系统层面的事件让某个视图多更新一两次（2026-09-24
//    连跑样本里约六遍一次，只会多、不会少），它不是这段代码的活；要求「两遍精确一致」
//    仍然挡得住真正的不确定。
// 2. 计数和基线**逐项相等**才算过：多了是退步；少了是进步，但必须把新数写进基线
//   （不然这次省下来的，下一个 PR 可以悄悄花回去）；多出来的项要登记，消失的项要删。
// 3. 内存峰值有噪声（runner 之间差 2–5%），按容差比：超上限算退步，降得多只提示。
// 4. **基线文件只许降。** 这个 PR 把任何一项基线改大了，就不许同时动产品代码
//    （Sources/ 下除 PreviewBench*.swift 以外的文件）—— 抬基线只有两种正当理由：
//    runner 的系统 / Xcode 换了，或者测试场景本身改了，这两种都不碰产品代码。

// MARK: - 数据

struct Baseline: Equatable, Codable {
    var fingerprint: String
    var memoryTolerance: Double
    var gated: [String: Int]
    var memory: [String: Double]

    init(fingerprint: String, memoryTolerance: Double, gated: [String: Int], memory: [String: Double]) {
        self.fingerprint = fingerprint
        self.memoryTolerance = memoryTolerance
        self.gated = gated
        self.memory = memory
    }

    init(json: [String: Any]) throws {
        guard let fingerprint = json["fingerprint"] as? String,
              let tolerance = json["memoryTolerance"] as? Double,
              let gated = json["gated"] as? [String: Int],
              let memory = json["memory"] as? [String: Double] else {
            throw CompareError("基线文件缺字段（fingerprint / memoryTolerance / gated / memory）")
        }
        self.init(fingerprint: fingerprint, memoryTolerance: tolerance, gated: gated, memory: memory)
    }

    /// 写成基线文件的样子。用 JSONEncoder 而不是 JSONSerialization：后者把 285.7 写成
    /// 285.69999999999999，提交进仓库没法读。
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

/// 一个场景跑一遍的结果（PreviewBench 写的 JSON）。
struct Run {
    var scenario: String
    var gated: [String: Int]
    var memory: [String: Double]
    var report: [String: Double]
    var breakdown: [String: [String: Int]]

    init(json: [String: Any], file: String) throws {
        if let error = json["error"] as? String {
            throw CompareError("\(file)：性能测试没跑完 —— \(error)")
        }
        guard let scenario = json["scenario"] as? String,
              let gated = json["gated"] as? [String: Int],
              let memory = json["memory"] as? [String: Double] else {
            throw CompareError("\(file)：结果缺字段（scenario / gated / memory）")
        }
        self.scenario = scenario
        self.gated = gated
        self.memory = memory
        self.report = json["report"] as? [String: Double] ?? [:]
        self.breakdown = json["breakdown"] as? [String: [String: Int]] ?? [:]
    }

    init(scenario: String, gated: [String: Int], memory: [String: Double]) {
        self.scenario = scenario
        self.gated = gated
        self.memory = memory
        self.report = [:]
        self.breakdown = [:]
    }
}

struct CompareError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - 判定

struct Verdict {
    var failures: [String] = []
    var notices: [String] = []
    /// 按这次实测改好的基线（进步 / 新增 / 删除都已写进去；退步的项保留旧值）。
    /// 改产品代码的 PR 用它。
    var proposed: Baseline
    /// 全部照这次实测（退步的项也是实测值）。只给「runner 环境变了 / 场景改了」那种
    /// 不碰产品代码的重定基线 PR 用。
    var measured: Baseline
    var passed: Bool { failures.isEmpty }
}

/// - Parameters:
///   - baseline: 这个提交里的基线。
///   - previous: 合并基准那一侧的基线（PR 的第一个父提交）。nil = 第一次引入。
///   - runs: 每个场景两遍：`[[第一遍, 第二遍], …]`。
///   - fingerprint: 这台 runner 的环境。
///   - touchesProductCode: 这个 PR 改没改 Sources/ 下除 PreviewBench*.swift 以外的文件。
func judge(
    baseline: Baseline, previous: Baseline?, runs: [[Run]],
    fingerprint: String, touchesProductCode: Bool
) -> Verdict {
    var verdict = Verdict(
        proposed: baseline,
        measured: Baseline(fingerprint: fingerprint, memoryTolerance: baseline.memoryTolerance, gated: [:], memory: [:])
    )
    verdict.proposed.fingerprint = fingerprint

    // 规则 4：基线只许降。
    if let previous {
        var raised: [String] = []
        for (key, value) in baseline.gated {
            if let old = previous.gated[key], value > old { raised.append("\(key) \(old) → \(value)") }
        }
        for (key, value) in baseline.memory {
            if let old = previous.memory[key], value > old { raised.append("\(key) \(old) → \(value)") }
        }
        if baseline.memoryTolerance > previous.memoryTolerance {
            raised.append("memoryTolerance \(previous.memoryTolerance) → \(baseline.memoryTolerance)")
        }
        if !raised.isEmpty {
            if touchesProductCode {
                verdict.failures.append(
                    "这个 PR 抬高了基线，同时又改了产品代码 —— 只许降不许涨。要加开销，先在别处省回同样多；"
                    + "只有 runner 环境变了、或者测试场景改了，才能单独开一个不碰产品代码的 PR 重定基线。抬高的项："
                    + raised.sorted().joined(separator: "；"))
            } else {
                verdict.notices.append("这个 PR 只重定基线（没动产品代码），抬高的项：" + raised.sorted().joined(separator: "；"))
            }
        }
    }

    var measuredGated: [String: Int] = [:]
    var measuredMemory: [String: Double] = [:]
    for scenarioRuns in runs {
        guard let first = scenarioRuns.first else { continue }
        // 规则 1：要有两遍一模一样。
        guard let (agreeing, outliers) = agreeingPair(scenarioRuns) else {
            verdict.failures.append(
                "场景 \(first.scenario) 跑了 \(scenarioRuns.count) 遍，没有两遍计数一模一样（测试本身不稳，不是基线的问题）："
                + differences(scenarioRuns[0], scenarioRuns[1]))
            continue
        }
        for outlier in outliers {
            verdict.notices.append(
                "场景 \(first.scenario) 有一遍和另外两遍不一样，当受干扰的那遍扔掉：" + differences(agreeing[0], outlier))
        }
        measuredGated.merge(agreeing[0].gated) { a, _ in a }
        for (key, _) in agreeing[0].memory {
            // 内存取一致那两遍里大的那个：宁可严一点。
            measuredMemory[key] = agreeing.compactMap { $0.memory[key] }.max()
        }
    }
    verdict.measured.gated = measuredGated
    verdict.measured.memory = measuredMemory

    // 规则 2：计数逐项相等。
    for key in Set(baseline.gated.keys).union(measuredGated.keys).sorted() {
        switch (baseline.gated[key], measuredGated[key]) {
        case let (old?, new?) where new > old:
            verdict.failures.append("退步：\(key) 基线 \(old)，这次 \(new)（+\(new - old)）")
        case let (old?, new?) where new < old:
            verdict.failures.append("进步了但没登记：\(key) 基线 \(old)，这次 \(new) —— 把基线改成 \(new)")
            verdict.proposed.gated[key] = new
        case (nil, let new?):
            verdict.failures.append("新的计数项没登记：\(key) = \(new)")
            verdict.proposed.gated[key] = new
        case (let old?, nil):
            verdict.failures.append("基线里的 \(key)（\(old)）这次没有了 —— 从基线里删掉")
            verdict.proposed.gated[key] = nil
        default:
            break
        }
    }

    // 规则 3：内存按容差。
    let tolerance = baseline.memoryTolerance
    for key in Set(baseline.memory.keys).union(measuredMemory.keys).sorted() {
        switch (baseline.memory[key], measuredMemory[key]) {
        case let (old?, new?):
            if new > old * (1 + tolerance) {
                verdict.failures.append(String(format: "退步：%@ 基线 %.1f MB，这次 %.1f MB（超出容差 %.0f%%）",
                                               key, old, new, tolerance * 100))
            } else if new < old * (1 - tolerance) {
                verdict.notices.append(String(format: "%@ 降到了 %.1f MB（基线 %.1f MB），可以把基线改小",
                                              key, new, old))
                verdict.proposed.memory[key] = new
            }
        case (nil, let new?):
            verdict.failures.append(String(format: "新的内存项没登记：%@ = %.1f MB", key, new))
            verdict.proposed.memory[key] = new
        case (let old?, nil):
            verdict.failures.append(String(format: "基线里的 %@（%.1f MB）这次没有了 —— 从基线里删掉", key, old))
            verdict.proposed.memory[key] = nil
        default:
            break
        }
    }

    if baseline.fingerprint != fingerprint {
        verdict.notices.append("基线记的环境是「\(baseline.fingerprint)」，这台 runner 是「\(fingerprint)」。"
            + "如果红在环境上，单独开一个不碰产品代码的 PR 重定基线。")
    }
    return verdict
}

/// 找出计数一模一样的两遍（按先后挑第一对），其余的是出局的那遍。一对都没有返回 nil。
func agreeingPair(_ runs: [Run]) -> (agreeing: [Run], outliers: [Run])? {
    for i in runs.indices {
        for j in runs.indices where j > i && runs[i].gated == runs[j].gated {
            let outliers = runs.indices.filter { $0 != i && $0 != j }.map { runs[$0] }
            return ([runs[i], runs[j]], outliers)
        }
    }
    return nil
}

/// 两遍之间不一样的项，「项 a / b」。
func differences(_ a: Run, _ b: Run) -> String {
    Set(a.gated.keys).union(b.gated.keys).sorted()
        .filter { a.gated[$0] != b.gated[$0] }
        .map { "\($0) \(a.gated[$0].map(String.init) ?? "无") / \(b.gated[$0].map(String.init) ?? "无")" }
        .joined(separator: "；")
}

// MARK: - 自检

func selfTest() -> Bool {
    var failures = 0
    func expect(_ condition: Bool, _ message: String, line: Int = #line) {
        if !condition {
            failures += 1
            print("FAIL [line \(line)] \(message)")
        }
    }
    let base = Baseline(fingerprint: "env A", memoryTolerance: 0.08,
                        gated: ["s.ticks.body": 100, "s.edits.composition.build": 2],
                        memory: ["s.memory.peakMB": 200])
    func run(_ gated: [String: Int], memory: Double = 200) -> Run {
        Run(scenario: "s", gated: gated, memory: ["s.memory.peakMB": memory])
    }
    let same = ["s.ticks.body": 100, "s.edits.composition.build": 2]

    var v = judge(baseline: base, previous: base, runs: [[run(same), run(same)]], fingerprint: "env A", touchesProductCode: true)
    expect(v.passed && v.notices.isEmpty, "一模一样应该过：\(v.failures)")

    v = judge(baseline: base, previous: base, runs: [[run(["s.ticks.body": 101, "s.edits.composition.build": 2]),
                                                       run(["s.ticks.body": 101, "s.edits.composition.build": 2])]],
              fingerprint: "env A", touchesProductCode: true)
    expect(!v.passed && v.failures.contains { $0.hasPrefix("退步：s.ticks.body") }, "多了一次要判退步")
    expect(v.proposed.gated["s.ticks.body"] == 100, "退步的项在建议基线里保留旧值")
    expect(v.measured.gated["s.ticks.body"] == 101, "「全部实测」那份要是实测值（重定基线用）")

    v = judge(baseline: base, previous: base, runs: [[run(["s.ticks.body": 52, "s.edits.composition.build": 2]),
                                                       run(["s.ticks.body": 52, "s.edits.composition.build": 2])]],
              fingerprint: "env A", touchesProductCode: true)
    expect(!v.passed && v.failures.contains { $0.hasPrefix("进步了但没登记") }, "降了没登记要判红")
    expect(v.proposed.gated["s.ticks.body"] == 52, "建议的基线要写进新低")

    v = judge(baseline: base, previous: base, runs: [[run(same), run(["s.ticks.body": 99, "s.edits.composition.build": 2])]],
              fingerprint: "env A", touchesProductCode: true)
    expect(!v.passed && v.failures.contains { $0.contains("没有两遍计数一模一样") }, "只跑了两遍、两遍不一样要判红")

    let noisy = ["s.ticks.body": 102, "s.edits.composition.build": 2]
    v = judge(baseline: base, previous: base, runs: [[run(same), run(noisy), run(same)]],
              fingerprint: "env A", touchesProductCode: true)
    expect(v.passed && v.notices.contains { $0.contains("当受干扰的那遍扔掉") },
           "三遍里有两遍一模一样：用那两遍，出局的那遍只提示：\(v.failures)")
    v = judge(baseline: base, previous: base, runs: [[run(noisy), run(same), run(same)]],
              fingerprint: "env A", touchesProductCode: true)
    expect(v.passed && v.measured.gated["s.ticks.body"] == 100, "第一遍出局时，数要取一致的那两遍")
    v = judge(baseline: base, previous: base,
              runs: [[run(same), run(noisy), run(["s.ticks.body": 104, "s.edits.composition.build": 2])]],
              fingerprint: "env A", touchesProductCode: true)
    expect(!v.passed && v.failures.contains { $0.contains("没有两遍计数一模一样") }, "三遍两两不同要判红")

    v = judge(baseline: base, previous: base, runs: [[run(same.merging(["s.ticks.canvas": 3]) { a, _ in a }),
                                                       run(same.merging(["s.ticks.canvas": 3]) { a, _ in a })]],
              fingerprint: "env A", touchesProductCode: true)
    expect(!v.passed && v.failures.contains { $0.hasPrefix("新的计数项没登记") }, "新增项要登记")

    v = judge(baseline: base, previous: base, runs: [[run(["s.ticks.body": 100]), run(["s.ticks.body": 100])]],
              fingerprint: "env A", touchesProductCode: true)
    expect(!v.passed && v.failures.contains { $0.contains("这次没有了") }, "消失的项要删")

    v = judge(baseline: base, previous: base, runs: [[run(same, memory: 214), run(same, memory: 210)]],
              fingerprint: "env A", touchesProductCode: true)
    expect(v.passed, "内存在容差内（+7%）应该过：\(v.failures)")
    v = judge(baseline: base, previous: base, runs: [[run(same, memory: 180), run(same, memory: 230)]],
              fingerprint: "env A", touchesProductCode: true)
    expect(!v.passed, "内存取两遍里大的：230 超出 8% 要判红")
    v = judge(baseline: base, previous: base, runs: [[run(same, memory: 150), run(same, memory: 150)]],
              fingerprint: "env A", touchesProductCode: true)
    expect(v.passed && !v.notices.isEmpty && v.proposed.memory["s.memory.peakMB"] == 150, "内存降多了只提示，不判红")

    var raised = base
    raised.gated["s.ticks.body"] = 120
    let raisedRuns = [[run(["s.ticks.body": 120, "s.edits.composition.build": 2]),
                       run(["s.ticks.body": 120, "s.edits.composition.build": 2])]]
    v = judge(baseline: raised, previous: base, runs: raisedRuns, fingerprint: "env B", touchesProductCode: true)
    expect(!v.passed && v.failures.contains { $0.contains("只许降不许涨") }, "抬基线同时改产品代码要判红")
    v = judge(baseline: raised, previous: base, runs: raisedRuns, fingerprint: "env B", touchesProductCode: false)
    expect(v.passed, "只重定基线、不碰产品代码可以抬：\(v.failures)")
    v = judge(baseline: raised, previous: nil, runs: raisedRuns, fingerprint: "env B", touchesProductCode: true)
    expect(v.passed, "第一次引入基线（没有上一版）不受只许降的约束：\(v.failures)")

    var looser = base
    looser.memoryTolerance = 0.2
    v = judge(baseline: looser, previous: base, runs: [[run(same), run(same)]], fingerprint: "env A", touchesProductCode: true)
    expect(!v.passed, "放宽内存容差也算抬基线")

    print(failures == 0 ? "✓ 比对规则自检全部通过" : "✗ 比对规则自检失败 \(failures) 条")
    return failures == 0
}

// MARK: - 命令行

func loadJSON(_ path: String) throws -> [String: Any] {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw CompareError("\(path) 不是 JSON 对象")
    }
    return object
}

func markdownSummary(_ verdict: Verdict, baseline: Baseline, runs: [[Run]], fingerprint: String) -> String {
    var lines = ["## 预览性能 ratchet", "", "环境：\(fingerprint)", ""]
    lines.append(verdict.passed ? "**通过**" : "**失败**")
    for failure in verdict.failures { lines.append("- ✗ \(failure)") }
    for notice in verdict.notices { lines.append("- ℹ︎ \(notice)") }
    lines += ["", "| 计数项 | 基线 | 这次 |", "| --- | ---: | ---: |"]
    let measured = verdict.measured.gated
    for key in Set(baseline.gated.keys).union(measured.keys).sorted() {
        let old = baseline.gated[key].map(String.init) ?? "—"
        let new = measured[key].map(String.init) ?? "—"
        lines.append("| `\(key)` | \(old) | \(old == new ? new : "**\(new)**") |")
    }
    lines += ["", "只报不卡（CPU 时间在 runner 之间差到两倍）：", "", "| 项 | 第一遍 | 第二遍 |", "| --- | ---: | ---: |"]
    for pair in runs {
        guard let first = pair.first else { continue }
        for key in first.report.keys.sorted() {
            let values = pair.map { $0.report[key].map { String(format: "%.0f", $0) } ?? "—" }
            lines.append("| `\(key)` | \(values.first ?? "—") | \(values.dropFirst().first ?? "—") |")
        }
    }
    // 时钟连跳、换选中时每个视图重算了几次：退步时一眼看出是谁。次数和 PreviewBench 的
    // tickCount / selectCount 对得上（这个脚本单独编，读不到那两个常量）。
    for pair in runs {
        guard let first = pair.first else { continue }
        for (phase, title) in [("ticks", "时钟连跳 60 下"), ("select", "换选中 8 次")] {
            guard let counts = first.breakdown["\(first.scenario).\(phase)"] else { continue }
            lines += ["", "\(first.scenario)：\(title)，各项计数", "", "| 项 | 次数 |", "| --- | ---: |"]
            for (key, count) in counts.sorted(by: { ($1.value, $0.key) < ($0.value, $1.key) }) {
                lines.append("| `\(key)` | \(count) |")
            }
        }
    }
    return lines.joined(separator: "\n") + "\n"
}

func main() -> Int32 {
    var args = Array(CommandLine.arguments.dropFirst())
    if args == ["--self-test"] { return selfTest() ? 0 : 1 }
    // 脚本用：这两遍的计数一样吗（不一样就再跑第三遍）。
    if args.count == 3, args[0] == "--same" {
        do {
            let a = try Run(json: loadJSON(args[1]), file: args[1])
            let b = try Run(json: loadJSON(args[2]), file: args[2])
            if a.gated == b.gated { return 0 }
            print("    两遍不一样：\(differences(a, b))")
            return 1
        } catch {
            print("✗ \(error)")
            return 2
        }
    }

    func take(_ flag: String) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        let value = args[index + 1]
        args.removeSubrange(index...(index + 1))
        return value
    }
    guard let baselinePath = take("--baseline"), let fingerprint = take("--fingerprint"),
          let touches = take("--touches-product-code"), let proposedPath = take("--proposed"),
          let measuredPath = take("--measured") else {
        print("用法：compare --baseline <json> [--previous <json>] --fingerprint <环境> "
            + "--touches-product-code <0|1> --proposed <输出> --measured <输出> [--summary <md>] "
            + "<场景-1.json> <场景-2.json> …")
        return 2
    }
    let previousPath = take("--previous")
    let summaryPath = take("--summary")
    do {
        let baseline = try Baseline(json: loadJSON(baselinePath))
        let previous = try previousPath.map { try Baseline(json: loadJSON($0)) }
        // 结果文件按场景名分组：<场景>-<第几遍>.json
        var grouped: [String: [Run]] = [:]
        for path in args.sorted() {
            let run = try Run(json: loadJSON(path), file: path)
            grouped[run.scenario, default: []].append(run)
        }
        guard !grouped.isEmpty else { throw CompareError("一份结果都没有") }
        for (scenario, runs) in grouped where runs.count < 2 {
            throw CompareError("场景 \(scenario) 只有 \(runs.count) 遍结果，要两遍才能判稳不稳")
        }
        let runs = grouped.keys.sorted().compactMap { grouped[$0] }
        let verdict = judge(baseline: baseline, previous: previous, runs: runs,
                            fingerprint: fingerprint, touchesProductCode: touches == "1")

        let proposed = try verdict.proposed.encoded()
        try proposed.write(to: URL(fileURLWithPath: proposedPath))
        try verdict.measured.encoded().write(to: URL(fileURLWithPath: measuredPath))
        let summary = markdownSummary(verdict, baseline: baseline, runs: runs, fingerprint: fingerprint)
        if let summaryPath {
            let handle = FileHandle(forWritingAtPath: summaryPath)
            handle?.seekToEndOfFile()
            handle?.write(Data(summary.utf8))
            try? handle?.close()
        }
        print(summary)
        if !verdict.passed {
            print("按这次实测改好的基线（进步、新增、删除都写进去了；退步的项保留原值）：")
            print(String(decoding: proposed, as: UTF8.self))
        }
        return verdict.passed ? 0 : 1
    } catch {
        print("✗ \(error)")
        return 1
    }
}

exit(main())
