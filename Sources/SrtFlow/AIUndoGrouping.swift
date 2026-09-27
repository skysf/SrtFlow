import Foundation

// MARK: - AI 的每个改动各是一步撤销
//
// 管什么：把一个 AI 工具里的撤销登记显式收成一组（`step`）。改工程的工具都从这里过。
// 不管什么：登记撤销本身（`VideoEditProject.perform` 那一条路照旧）。
//
// 为什么不能靠默认的「按事件分组」：撤销管理器登记时自动开一组，**要等下一个用户事件才关上**。
// AI 的调用不是事件，App 又常在后台一个事件都收不到 —— AI 的每一步都堆进同一组，⌘Z 一按全部
// 退光（2026-09-27 端到端实测：撤一步，整条时间线空了，
// docs/bugfixes/2026-09-27-ai-edits-share-one-undo-group.md）。
//
// **也不能去手动关那个自动组**（第一版就是这么修的）：关掉之后撤销管理器还记着「这一轮事件的组
// 已经开过了」，下一次登记（下一个 AI 调用）直接抛 NSInternalInconsistencyException
// （must begin a group before registering undo），整个 App 闪退 —— 自检在命令行里当场复现。
//
// 所以这里**绕开**按事件分组：暂时关掉它、自己开一组、做完关上、再恢复。必须是同步的一段
// （不许有 await）：中途让出主线程的话，用户这时的操作会落进这一组，⌘Z 甚至能把这一组提前关掉。
// 进来时已经开着一组（用户刚做完、还没等到下一个事件的那一组）就不另开，嵌在里面 —— 两步并成
// 一步，但不会崩。

enum AIUndoGrouping {
    static func step<T>(_ manager: UndoManager?, _ body: () throws -> T) rethrows -> T {
        guard let manager, manager.groupingLevel == 0 else { return try body() }
        let byEvent = manager.groupsByEvent
        manager.groupsByEvent = false
        manager.beginUndoGrouping()
        defer {
            // 中间有人清空了撤销栈（removeAllActions 会把开着的组一起丢掉），就没有组可关了。
            if manager.groupingLevel > 0 { manager.endUndoGrouping() }
            manager.groupsByEvent = byEvent
        }
        return try body()
    }
}
