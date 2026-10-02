import Foundation
import SrtFlowCore

// MARK: - 一段剪辑的声音与速度：变速、音量、静音、渐入渐出、分离音频
//
// 从 VideoEditProject.swift 搬出来的（那个文件在行数基线上只许降不许涨，2026-10-02 联动的钩子进去时顺手搬的）：
// 这几个入口都是「选中一段、改它自己的声音 / 速度」，一次 perform 一步撤销；夹紧各自写在入口里，
// 渐入渐出的夹紧只有 `audioFadeMutation` 一份（discrete 和 live 永不分叉，Inspector 数值框合同）。
// 变速和分离音频牵扯链接组（`linkedClipIDs`）：联动开着时一起变速、分离出来的那段和视频绑成一组。
// 不管什么：轨道推子 / 总推子（VideoEditProject+Mixer.swift）、音量曲线（VideoEditProject+VolumeCurve.swift）。

extension VideoEditProject {
    func setSpeed(_ id: UUID, speed: Double) {
        let clamped = min(max(speed, 0.1), 8)
        let ids = linkageEnabled ? state.linkedClipIDs(of: id) : [id]
        perform { state in
            for member in ids {
                state.update(member) { $0.speed = clamped }
            }
        }
    }

    func setVolume(_ id: UUID, volume: Double) {
        perform { state in
            state.update(id) { $0.volume = min(max(volume, 0), 2) }
        }
    }

    func setMuted(_ id: UUID, muted: Bool) {
        perform { state in
            state.update(id) { $0.isMuted = muted }
        }
    }

    /// 声音渐入/渐出（时间线秒）。文本提交和箭头点击走这条，一次一步撤销。
    func setAudioFade(_ id: UUID, edge: AudioFadeEdge, seconds: Double) {
        perform(audioFadeMutation(id, edge: edge, seconds: seconds))
    }

    /// Inspector 数值框横向拖调用：同 `setAudioFade`，整次拖动结成一步。
    func liveSetAudioFade(_ id: UUID, edge: AudioFadeEdge, seconds: Double) {
        liveApply(audioFadeMutation(id, edge: edge, seconds: seconds))
    }

    /// 夹紧只写在这一份里，discrete 和 live 永不分叉（Inspector 数值框合同）。
    /// 这里只挡住负数和 NaN，「不超过段长」由 `EditClip.audioFades` 在读侧统一
    /// 收口 —— 存的是用户设的意图，段被拉长之后渐变应当跟着恢复，而不是在
    /// 写入那一刻就被当时的段长永久截短。
    private func audioFadeMutation(
        _ id: UUID, edge: AudioFadeEdge, seconds: Double
    ) -> (inout TimelineState) -> Void {
        let clamped = max(0, seconds.isFinite ? seconds : 0)
        return { state in
            state.update(id) { clip in
                switch edge {
                case .fadeIn: clip.fadeInDuration = clamped
                case .fadeOut: clip.fadeOutDuration = clamped
                }
            }
        }
    }

    /// 把视频段的声音分离成音频轨上的一段，两边用链接组绑在一起。
    func detachAudio(from id: UUID) {
        guard let clip = state.clip(with: id), !clip.isAudioOnly, clip.hasAudio, !clip.isMuted else { return }
        perform { state in
            let group = clip.linkGroup ?? UUID()
            // 源还是那个视频文件，isAudioOnly 只表示这段只取它的声音。
            // 音量 / 曲线 / 渐变跟着声音走（见 `EditClip.detachedAudio`）。
            let detached = clip.detachedAudio(linkGroup: group)
            state.update(id) { original in
                original.isMuted = true
                original.linkGroup = group
            }
            _ = state.place(detached, intoAudio: true)
        }
    }
}
