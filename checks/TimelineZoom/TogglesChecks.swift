import Foundation

// 剪辑页上记住的开关（EditorToggles，Sources/SrtFlow/EditorToggles.swift）：默认值是产品口径、记住的读回来、
// 记坏的当没记、脚本驱动（性能测试 / 冒烟）时永远默认值且写不落盘。由 main.swift 调。
// 用一个自己的 suite 读写，开头和结尾都清掉，不碰这台机器上 App 真正的设置。

func runEditorTogglesChecks() {
    typealias Key = EditorToggles.Key
    let suiteName = "com.srtflow.checks.EditorToggles"
    guard let suite = UserDefaults(suiteName: suiteName) else {
        check(false, "开不出自检用的 UserDefaults suite")
        return
    }
    suite.removePersistentDomain(forName: suiteName)
    defer { suite.removePersistentDomain(forName: suiteName) }

    // 1. 默认值 = 产品口径：只开吸附（2026-09-18），播放跟随、字幕列表跟随默认关（2026-10-01）。
    check(Key.allCases.count == 5, "五个开关，一个不多一个不少（加开关要同步这里和文档）")
    check(Key.magnet.defaultValue == false, "磁吸默认关：用户的剪法要留间隙")
    check(Key.snapping.defaultValue == true, "吸附默认开：它不改任何自动行为")
    check(Key.linkage.defaultValue == true, "联动默认开（2026-10-02，同剪映）：关着剪掉一段之后后面的字幕、音效全错位")
    check(Key.followPlayhead.defaultValue == false, "播放跟随默认关：播放时轨道区域停在哪就停在哪")
    check(Key.subtitleListFollows.defaultValue == false, "字幕列表默认不跟着播放滚")
    check(Set(Key.allCases.map(\.rawValue)).count == Key.allCases.count, "五个键互不相同")

    // 2. 没记过 → 默认值；记了 → 读回来；记坏的（不是布尔）→ 当没记。
    for key in Key.allCases {
        check(EditorToggles.read(key, from: suite) == key.defaultValue, "\(key) 没记过时读到默认值")
        EditorToggles.write(key, !key.defaultValue, to: suite)
        check(EditorToggles.read(key, from: suite) == !key.defaultValue, "\(key) 记了反过来的值就读到反过来的值")
        EditorToggles.write(key, key.defaultValue, to: suite)
        check(EditorToggles.read(key, from: suite) == key.defaultValue, "\(key) 再记回默认值也读得回来（不是「有键就算 true」）")
        suite.set("yes", forKey: key.rawValue)
        check(EditorToggles.read(key, from: suite) == key.defaultValue, "\(key) 记的不是布尔时当没记")
        suite.removeObject(forKey: key.rawValue)
    }

    // 3. 脚本驱动时没有地方可记：读永远默认值、写丢掉（下一次读还是默认值）。
    check(EditorToggles.store(scripted: true) == nil, "性能测试 / 冒烟开着时没有 store")
    check(EditorToggles.store(scripted: false) === UserDefaults.standard, "平时记在 UserDefaults.standard")
    EditorToggles.write(.followPlayhead, true, to: nil)
    check(EditorToggles.read(.followPlayhead, from: nil) == false, "没有 store 时写了也读不到（起手永远是默认值）")
    EditorToggles.write(.snapping, false, to: nil)
    check(EditorToggles.read(.snapping, from: nil) == true, "没有 store 时吸附还是默认开")
}
