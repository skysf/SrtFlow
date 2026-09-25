import SwiftUI

/// 预览左边那一栏：转场库、滤镜库和音频库共用，顶上一个分段切换。
///
/// 为什么共用一栏而不是并排几栏：宽度预算不够。库 196 + 预览 430 + 检查器 252
/// = 878，已经贴着窗口最小宽度 900；再开一栏必须把窗口最小宽度抬上去，而这几个
/// 库从来不需要同时看着（挑转场、挑滤镜、挑配乐是三件事）。
///
/// 分段切换本身就是这一栏的标题，所以各面板都**不再画自己的标题行** ——
/// 画了就是一栏里两行标题，把本来就窄的格子再吃掉一截。
///
/// **三段起只显示图标**（2026-09-22 加音频页时）：196pt 里塞三个「图标 + 文字」，
/// 英文下 Transitions / Filters / Audio 会被截成看不出意思的残词。靠 `.instantHelp`
/// 认路 —— 仓库本来就禁用系统 `.help`，这条是白捡的（见 instant-tooltips.md）。
///
/// **这一栏不订阅时钟**：转场、滤镜两页只跟「停稳了的播放头」（`clock.atRest`）—— 播放中、
/// 拖播放头的过程中一动不动，鼠标在时间线上扫也不算，停稳了刷新一次（2026-09-25 用户拍板：
/// 播放时小样来回换没有用，还把播放拖卡）。
struct LibraryColumn: View {
    @ObservedObject var project: VideoEditProject

    enum Tab: String, CaseIterable, Identifiable {
        case transitions, filters, audio

        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .transitions: return "Transitions"
            case .filters: return "Filters"
            case .audio: return "Audio"
            }
        }

        var icon: String {
            switch self {
            case .transitions: return "square.filled.and.line.vertical.and.square"
            case .filters: return "camera.filters"
            case .audio: return "music.note"
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
        let _ = PerfCounters.body(Self.self)
        VStack(alignment: .leading, spacing: 0) {
            Picker("", selection: tab) {
                ForEach(Tab.allCases) { item in
                    Label(item.title, systemImage: item.icon)
                        .labelStyle(.iconOnly)
                        .instantHelp(item.title)
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
                TransitionLibraryPanel(project: project, playhead: project.clock.atRest)
            case .filters:
                FilterLibraryPanel(project: project, playhead: project.clock.atRest)
            case .audio:
                AudioLibraryPanel(project: project)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
