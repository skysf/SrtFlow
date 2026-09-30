import Foundation

// MARK: - 合成一个音效、写成文件（add_clips 的 sound_effect 条目）
//
// 管什么：文件放在 `<起点>/SrtFlow/音效`（AIWorkspace.Output.soundEffects），名字 = 预设 + 参数哈希
// （SoundEffectParameters.fileStem）：同参数同文件，已经有了就不再写（不算覆盖，也不用问）；渲染（几十毫秒的纯计算）和写盘在
// MediaReadQueue.analysis 上跑、不占 Swift 并发的线程池（docs/architecture/blocking-media-reads.md）；写文件只经 AIAudioFileWriter
// （同配音，scripts/check-mcp.sh 扫描钉着）。
// 不管什么：参数怎么读、落点怎么算（AISoundEffectRequest）、放上时间线（AITimelineTools）。

@MainActor
enum AISoundEffectTool {
    struct Made {
        var parameters: SoundEffectParameters
        var url: URL
        /// 声音里的落点（秒）
        var hitAt: Double
        var hitKind: SoundEffectRender.HitKind
        var seconds: Double
        /// 文件本来就在（同参数做过）
        var reused: Bool
    }

    static func make(_ parameters: SoundEffectParameters, project: VideoEditProject) async throws -> Made {
        let folder = AIWorkspace.shared.outputFolder(.soundEffects, project: project)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(parameters.fileStem).appendingPathExtension("m4a")
        let exists = FileManager.default.fileExists(atPath: url.path)
        let outcome = await MediaReadQueue.run(on: MediaReadQueue.analysis) { () -> (render: SoundEffectRender, error: String?) in
            let render = SoundEffectSynth.render(parameters)
            guard !exists else { return (render, nil) }
            do {
                try AIAudioFileWriter.writeSoundEffect(render.audio.floatChannels, sampleRate: SFX.sampleRate, to: url)
                return (render, nil)
            } catch let error as AIToolError {
                return (render, error.message)
            } catch {
                return (render, error.localizedDescription)
            }
        }
        if let message = outcome.error { throw AIToolError(message) }
        return Made(parameters: parameters, url: url, hitAt: outcome.render.hitAt, hitKind: outcome.render.hitKind,
                    seconds: outcome.render.audio.seconds, reused: exists)
    }
}
