import Foundation

// MARK: - 编辑器出现时的开发钩子
//
// 管什么：GUI 冒烟和性能测试靠环境变量挂进编辑器的那几个入口。**环境变量不设就完全
// 不生效**，正式包可以安全保留。
// 不管什么：各钩子自己的逻辑（PreviewBench、SmokeDriver）。
//
// 从 VideoEditView.onAppear 挪出来（那个文件超过 600 行、只许降）：钩子越加越多，
// 挤在视图的生命周期回调里既难找，也让视图文件背着一堆和界面无关的注释。

@MainActor
enum DevHooks {
    static func editorAppeared(project: VideoEditProject) {
        let env = ProcessInfo.processInfo.environment
        // 导入钩子：可以用 : 分隔多个路径（PATH 惯例），addMedia 按类型分流 —— 想验
        // 字幕相关的界面就再挂一个 .srt，否则拿不到「有字幕」的状态。
        if let smoke = env["SRTFLOW_SMOKE_VIDEO"], !smoke.isEmpty, project.state.isEmpty {
            let urls = smoke.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
            project.addMedia(urls: urls)
        }
        // 同一套钩子，打开一份**已存在的工程**。
        //
        // 为什么非要有它：音频库素材的重链接（`remoteKey` → 缓存 → R2）只在
        // **打开工程**这条路径上跑，而那条路自动化进不去 —— 临时目录里 ad-hoc
        // 签名的调试拷贝没在 LaunchServices 注册文档类型，命令行参数、
        // `open -a`、AppleScript 的 `open` 三条路 2026-09-22 实测全部打不开它，
        // 而 NSOpenPanel 的自动化本来就不可靠（见 gui-smoke-testing.md）。
        // 没有这个钩子，「清掉缓存还找不找得回来」这条就永远只能靠人手点。
        if let smoke = env["SRTFLOW_SMOKE_PROJECT"], !smoke.isEmpty, project.state.isEmpty {
            let url = URL(fileURLWithPath: smoke)
            Task { await project.openProject(at: url) }
        }
        // 预览性能测试：只有 CI 上 scripts/check-preview-perf.sh 起的 App 才带
        // `SRTFLOW_BENCH_OUT`，平时是空操作（PreviewBench.swift）。
        PreviewBench.startIfRequested(project: project)
        // 进程内冒烟脚本：不接管鼠标、不抢焦点地点 / 拖 / 滚 / 按键（SmokeDriver.swift）。
        SmokeDriver.startIfRequested(project: project)
    }
}
