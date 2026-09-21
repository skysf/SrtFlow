import SwiftUI

/// 预览左边那一栏：转场库和滤镜库共用，顶上一个分段切换。
///
/// 为什么共用一栏而不是并排两栏：宽度预算不够。库 196 + 预览 430 + 检查器 252
/// = 878，已经贴着窗口最小宽度 900；再开一栏必须把窗口最小宽度抬上去，而那两个
/// 库从来不需要同时看着（挑转场和挑滤镜是两件事）。
///
/// 分段切换本身就是这一栏的标题，所以两个面板各自都**不再画自己的标题行** ——
/// 画了就是一栏里两行标题，把本来就窄的格子再吃掉一截。
struct LibraryColumn: View {
    @ObservedObject var project: VideoEditProject
    @ObservedObject var clock: PlayerClock

    enum Tab: String, CaseIterable, Identifiable {
        case transitions, filters

        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .transitions: return "Transitions"
            case .filters: return "Filters"
            }
        }

        var icon: String {
            switch self {
            case .transitions: return "square.filled.and.line.vertical.and.square"
            case .filters: return "camera.filters"
            }
        }
    }

    /// 记住上次看的是哪一页 —— 它是布局偏好，不是工程数据。
    @AppStorage("libraryColumnTab") private var tabRaw = Tab.transitions.rawValue

    private var tab: Binding<Tab> {
        Binding(
            get: { Tab(rawValue: tabRaw) ?? .transitions },
            set: { tabRaw = $0.rawValue }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("", selection: tab) {
                ForEach(Tab.allCases) { item in
                    Label(item.title, systemImage: item.icon)
                        .labelStyle(.titleAndIcon)
                        .tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            Divider()
            switch tab.wrappedValue {
            case .transitions:
                TransitionLibraryPanel(project: project, clock: clock)
            case .filters:
                FilterLibraryPanel(project: project, clock: clock)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
