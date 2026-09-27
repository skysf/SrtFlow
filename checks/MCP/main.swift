import Foundation

// AI 接口（MCP）的自检入口。编法与运行见 scripts/check-mcp.sh；
// 规则的出处见 docs/architecture/ai-control-mcp.md。

runProtocolChecks()
runTimelineChecks()
runConfigChecks()

if failures > 0 {
    print("✗ \(failures) of \(checks) MCP checks failed.")
    exit(1)
}
print("All \(checks) MCP checks passed.")
