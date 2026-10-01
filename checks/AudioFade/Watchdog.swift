import Foundation

// 看门狗：这项自检渲混音（引擎离线渲、ffmpeg 真跑导出）都是同步阻塞的，哪一步卡住，整个脚本就一声不吭地
// 挂到 CI 的 30 分钟超时 —— 2026-09-27 PR #81 实测，日志里「运行」之后什么都没有，连卡在哪一组都不知道
// （print 进管道是整块缓冲的，前面跑完的组也没吐出来）。
// 这里做两件事：标准输出改成逐行写出；普通线程上计时，超时就说出正在跑哪一组、判红退出。
// 编译方式见 scripts/check-audio-fade.sh。

private let groupLock = NSLock()
private var runningGroup = "开始之前"

/// 进入一组：记下来、打一行，卡住时看门狗说得出是哪一组。
func group(_ name: String) {
    groupLock.lock()
    runningGroup = name
    groupLock.unlock()
    print("-- \(name)")
}

func startWatchdog(seconds: TimeInterval) {
    setvbuf(stdout, nil, _IOLBF, 0)
    Thread.detachNewThread {
        Thread.sleep(forTimeInterval: seconds)
        groupLock.lock()
        let name = runningGroup
        groupLock.unlock()
        print("✗ 自检跑了 \(Int(seconds)) 秒还没完，卡在：\(name)（引擎离线渲或 ffmpeg 没回来）")
        fflush(stdout)
        exit(1)
    }
}
