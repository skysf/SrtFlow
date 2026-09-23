import Foundation

// MARK: - 音量曲线的写入口
//
// 块上那条线的所有落地都走这几个方法，每一次都是**一步撤销**、只换 audioMix
//（`differsOnlyInAudioMix` 已经把曲线抹平，画面不闪）。编辑规则本身是纯值，在
// VideoEditVolumeCurve.swift；合同见 docs/architecture/audio-volume-curve.md。

extension VideoEditProject {
    /// 拖线 / 拖点松手：把手势算出来的那一份（从起手时的段出发）整份落下。
    /// 只写音量这两个字段 —— 手势期间段的别的属性没人动，但也不该由它来覆盖。
    func commitVolumeEdit(_ id: UUID, edited: EditClip) {
        perform { state in
            state.update(id) { clip in
                clip.volume = edited.volume
                clip.volumeCurve = edited.volumeCurve
            }
        }
    }

    /// ⌥ 点线：在这一刻加一个点（取线上此刻的值，加点本身不改声音）。
    func addVolumePoint(_ id: UUID, atTimeline time: Double) {
        perform { state in
            state.update(id) { $0.addVolumePoint(atTimeline: time) }
        }
    }

    /// ⌥ 点点：删掉它（删最后一个时值固化进 `volume`，线原地不动）。
    func removeVolumePoint(_ id: UUID, at index: Int) {
        perform { state in
            state.update(id) { $0.removeVolumePoint(at: index) }
        }
    }

    /// 右键「去掉音量曲线」：回到画曲线之前的那条水平线。
    func removeVolumeCurve(_ id: UUID) {
        perform { state in
            state.update(id) { $0.removeVolumeCurve() }
        }
    }

    /// 检查器的「回到 0 dB」：曲线一起去掉，整段回到原样。
    func resetVolume(_ id: UUID) {
        perform { state in
            state.update(id) { clip in
                clip.removeVolumeCurve()
                clip.volume = 1
            }
        }
    }
}
