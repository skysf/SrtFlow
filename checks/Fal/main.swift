import Foundation

// fal.ai 生成（方案第 6 块）的自检入口。编法与运行见 scripts/check-fal.sh；
// 规则的出处见 docs/architecture/fal-generation.md。

runRegistryChecks()
runSpendChecks()
runInputChecks()
runOutputChecks()
await runClientChecks()
runKeyChecks()

if failures > 0 {
    print("✗ \(failures) of \(checks) fal checks failed.")
    exit(1)
}
print("All \(checks) fal checks passed.")
