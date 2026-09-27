import Foundation
import SrtFlowMCPKit

// MARK: - set_track：一条轨的推子、藏起来，以及总推子（纯值）
//
// 管什么：AI 说「A1 压低 12 dB」「把 V2 藏起来」「总音量 −3 dB」时怎么改 TimelineState。推子走
// `TimelineState.setTrackVolume`（夹紧只在那一处，轨道头的推子也是它），总推子照 `setMasterVolume` 的
// `AudioGain.clampedLinear`；藏起来直接写那条轨的眼睛（界面上是按眼睛切换，这里给的是绝对值）。
// 不管什么：轨道名怎么认（AITrackName）、提交和撤销（AITimelineTools / 路由）。

enum AITrackSettings {
    enum Target: Equatable {
        case track(TrackSlot)
        case master
    }

    /// 轨道名 → 要改的东西。只认现有的轨（set_track 不开新轨）。
    static func target(_ name: String, in state: TimelineState) throws -> Target {
        if name.trimmingCharacters(in: .whitespaces).lowercased() == "master" { return .master }
        switch try AITrackName.target(name, in: state) {
        case .main: return .track(.main)
        case .overlay(let index): return .track(.overlay(index))
        case .audio(let index): return .track(.audio(index))
        default: throw AIToolError("There is no track \(name.uppercased()) yet; set_track changes existing tracks (or \"master\").")
        }
    }

    static func apply(_ target: Target, volumeDB: Double?, hidden: Bool?, in state: inout TimelineState) throws {
        switch target {
        case .master:
            guard hidden == nil else { throw AIToolError("The master fader cannot be hidden; hide tracks one by one.") }
            if let volumeDB {
                state.masterVolume = AudioGain.clampedLinear(AudioGain.linear(fromDecibels: AudioGain.clampedDecibels(volumeDB)))
            }
        case .track(let slot):
            if let volumeDB {
                state.setTrackVolume(AudioGain.linear(fromDecibels: AudioGain.clampedDecibels(volumeDB)), for: slot)
            }
            if let hidden {
                switch slot {
                case .main: state.mainHidden = hidden
                case .overlay(let index): state.overlayTracks[index].isHidden = hidden
                case .audio(let index): state.audioTracks[index].isHidden = hidden
                }
            }
        }
    }

    /// 推子写成 dB（一位小数）。
    static func decibels(_ linear: Double) -> JSONValue {
        .number((AudioGain.decibels(fromLinear: linear) * 10).rounded() / 10)
    }
}
