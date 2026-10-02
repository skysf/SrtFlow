import SwiftUI

// MARK: - 把 Upscale 面板和对比窗口摆出来
//
// 管什么：一个不画东西的小视图，挂在检查器底下（检查器在剪辑页里一直在），只订阅 `UpscaleActivity` 的 `panel` / `compare`：
// 右键菜单、检查器、做完的任务都往那两个字段里写，sheet 从这里出。sheet 不继承应用内语言，各套一层 `.appLanguage()`
//（checks/presented-views-app-language.sh）。
// 不管什么：面板和窗口里面（UpscalePanel、UpscaleCompareView）。

struct UpscalePresenter: View, Equatable {
    let project: VideoEditProject
    @ObservedObject private var activity = UpscaleActivity.shared

    /// 检查器每重算一次都会重新造它：按工程的身份比，一样就不重算 body（性能 ratchet 数着）。
    static func == (lhs: UpscalePresenter, rhs: UpscalePresenter) -> Bool { lhs.project === rhs.project }

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        Color.clear
            .frame(width: 0, height: 0)
            .sheet(item: $activity.panel) { target in
                if let model = UpscalePanelModel(project: project, clipID: target.id) {
                    UpscalePanel(project: project, model: model).appLanguage()
                } else {
                    // 这一段已经不在了 / 不是画面段：什么都不摆（点错了也不该弹个空面板）。
                    Color.clear.frame(width: 1, height: 1).onAppear { activity.panel = nil }
                }
            }
            .sheet(item: $activity.compare) { target in
                UpscaleCompareView(project: project, target: target).appLanguage()
            }
    }
}
