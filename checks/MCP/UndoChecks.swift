import Foundation

// AI 的每个改动各是一步撤销（docs/bugfixes/2026-09-27-ai-edits-share-one-undo-group.md）。
//
// 用真的 UndoManager 复现：命令行里和后台的 App 一样，一个用户事件都没有，按事件分组自动开的
// 那一组就一直不关。第一段证明这个前提（两步并成一步），第二段证明 AIUndoGrouping.step 把它们分开，
// 第三段钉住第一版修法的那个崩溃（手动关掉自动组之后，下一次登记就抛异常、App 闪退）不会再出现：
// 走完几步 step 之后，按事件的普通登记照样能开组。
// 路由确实把改工程的工具都包了一层，由 scripts/check-mcp.sh 里的扫描那一段钉着。

private final class Counter {
    var value = 0
    func bump(_ manager: UndoManager) {
        value += 1
        manager.registerUndo(withTarget: self) { $0.value -= 1 }
    }
}

func runUndoChecks() {
    // 前提：不分组的话，两次登记落在同一组里，一次 undo 全退。
    let merged = UndoManager()
    let a = Counter()
    a.bump(merged)
    a.bump(merged)
    checkEqual(merged.groupingLevel, 1, "without events the automatic group stays open")
    merged.undo()
    checkEqual(a.value, 0, "an open automatic group makes one undo take back both edits")

    // 修复：每一步显式一组，一次 undo 只退一步。
    let separate = UndoManager()
    let b = Counter()
    AIUndoGrouping.step(separate) { b.bump(separate) }
    AIUndoGrouping.step(separate) { b.bump(separate) }
    checkEqual(separate.groupingLevel, 0, "each step leaves no group open")
    check(separate.groupsByEvent, "grouping by event is switched back on after a step")
    separate.undo()
    checkEqual(b.value, 1, "one undo takes back only the latest AI step")
    separate.undo()
    checkEqual(b.value, 0, "the next undo takes back the step before")

    // 第一版修法的崩溃不会再来：几步 step 之后，按事件的普通登记（用户在界面上的操作）照样能开组，
    // 不抛 "must begin a group before registering undo"。
    b.bump(separate)
    checkEqual(separate.groupingLevel, 1, "a normal registration after AI steps still opens its automatic group")

    // 进来时已经开着一组（用户刚做完、还没等到下一个事件）：嵌在里面，不崩，也不另开。
    let pending = UndoManager()
    let c = Counter()
    c.bump(pending)
    AIUndoGrouping.step(pending) { c.bump(pending) }
    checkEqual(pending.groupingLevel, 1, "inside a pending group the step nests instead of opening another")
    checkEqual(c.value, 2, "both edits happened")

    // 中间有人清空了撤销栈（新建 / 打开工程会这么做）：不许去关一个已经不存在的组。
    let cleared = UndoManager()
    AIUndoGrouping.step(cleared) { cleared.removeAllActions() }
    checkEqual(cleared.groupingLevel, 0, "clearing inside a step does not unbalance the groups")
    check(cleared.groupsByEvent, "grouping by event is back on after a cleared step")
}
