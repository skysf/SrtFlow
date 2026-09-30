import SwiftUI

// MARK: - 侧边栏收起时的语言菜单
//
// 管什么：图标条里只画旗子的语言选择。
// 不管什么：语言的存取（AppLanguage.swift）。
//
// 单独一个文件是因为 `AppLanguage.swift` 在好几个自检脚本的源文件清单里，而它们不编
// `InstantTooltip.swift`：`instantHelp` 写在那边自检就编不过（PR #115 首跑 CI）。

/// 侧边栏收成图标条时的语言选择：只画当前语言的旗子（60pt 宽放不下带文字的菜单），
/// 点开是同一份选项，每项带旗子和那种语言自己的名字。
struct AppLanguageFlagMenu: View {
    @ObservedObject private var store = AppLanguageStore.shared

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        Menu {
            Picker("Language", selection: $store.language) {
                ForEach(AppLanguage.allCases) { option in
                    Text(verbatim: "\(option.flag)  \(option.nativeName)").tag(option)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(verbatim: store.language.flag)
                .font(.title3)
                .frame(width: 28, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .instantHelp("Language")
    }
}
