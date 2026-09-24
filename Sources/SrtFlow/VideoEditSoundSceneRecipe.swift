import AudioToolbox
import Foundation

// MARK: - 九种场景的配方：用哪几个效果单元、两个旋钮换算成什么参数
//
// 旋钮都是 0…1（`SoundScene.first` / `second`）。喇叭类是「失真」「音质」，空间类是「空间大小」「距离」
// （`SoundSceneKind.controls`）。**参数一律自己设**，不载入单元的出厂预设：2026-09-24 探针发现 AUReverb2
// 载入预设后 Dry/Wet 读回来是 0.5（满量程 100），预设靠不住。参数编号与量程见当天探针的单元目录
// （docs/plans/2026-09-24-sound-scenes.md 第三节）。
//
// 各单元自己的干湿比都按「场景里听到的那一份」设（喇叭类全湿，空间类按距离混一部分直达声）；
// 检查器的「强度」是在这份之外、由 SceneTrackRenderer 和原声交叉混的，和这里无关。

enum SceneRecipe {
    /// 一种场景用哪几个单元（按顺序串起来）。
    static func units(for kind: SoundSceneKind) -> [OSType] {
        switch kind {
        // 喇叭类先削波、最后才限带：真的电话 / 喇叭也是电路里失真、听筒 / 喇叭口把频带卡死；
        // 反过来的话削波会在限好的频带外重新长出高次谐波（2026-09-24 自检量到过）。
        case .telephone, .megaphone, .radio: return [kAudioUnitSubType_Distortion, kAudioUnitSubType_NBandEQ]
        case .room, .bathroom, .hall: return [kAudioUnitSubType_Reverb2]
        case .forest: return [kAudioUnitSubType_NBandEQ, kAudioUnitSubType_Reverb2]
        case .outdoor: return [kAudioUnitSubType_NBandEQ, kAudioUnitSubType_Delay]
        case .valley: return [kAudioUnitSubType_Delay, kAudioUnitSubType_Reverb2]
        }
    }

    /// 余音最长多久（所有场景、所有旋钮位置里最长的那条）。挂了场景的合成音轨最后一段后面就垫这么长
    /// 一截素材（SceneTailCarrier）—— 固定长度，拖旋钮不改合成结构。
    static let maximumTail = 6.0

    /// 把旋钮换算成参数设进 `units`（顺序同 `units(for:)`），返回余音要多长（秒）。
    static func configure(_ units: [SceneUnit], kind: SoundSceneKind, first f: Double, second g: Double) -> Double {
        switch kind {
        case .telephone:
            // 电话：300–3400Hz 那一条窄带，1.8kHz 一点鼻音，轻微削波。
            speakerEQ(units[1], low: lerp(450, 200, g), high: lerp(2800, 5000, g), peak: 1800, peakGain: 3, peakWidth: 1)
            distortion(units[0], drive: lerp(-6, 12, f), polynomial: lerp(0, 40, f), cubic: lerp(0, 6, f), squared: lerp(0, 2, f))
            return 0.1
        case .megaphone:
            // 扩音器：更窄、2kHz 喇叭口的共振、明显的削波。
            speakerEQ(units[1], low: lerp(650, 350, g), high: lerp(3500, 6000, g), peak: 2000, peakGain: 6, peakWidth: 0.8)
            distortion(units[0], drive: lerp(0, 18, f), polynomial: lerp(30, 80, f), cubic: lerp(4, 16, f), squared: lerp(1, 4, f))
            return 0.1
        case .radio:
            // 收音机：比电话宽一些、失真轻。
            speakerEQ(units[1], low: lerp(250, 120, g), high: lerp(4000, 7500, g), peak: 1200, peakGain: 2, peakWidth: 1.5)
            distortion(units[0], drive: lerp(-12, 6, f), polynomial: lerp(0, 25, f), cubic: lerp(0, 3, f), squared: 0)
            return 0.1
        case .room:
            return reverb(units[0], decay: lerp(0.25, 1.0, f), brightness: 0.4,
                          minDelay: lerp(0.002, 0.008, f), maxDelay: lerp(0.02, 0.06, f), wet: lerp(15, 50, g))
        case .bathroom:
            // 浴室：瓷砖反射强、亮（高频衰减慢），早期反射密。
            return reverb(units[0], decay: lerp(0.6, 1.6, f), brightness: 0.85,
                          minDelay: lerp(0.001, 0.004, f), maxDelay: lerp(0.01, 0.03, f), wet: lerp(25, 60, g))
        case .hall:
            return reverb(units[0], decay: lerp(1.5, 3.5, f), brightness: 0.6,
                          minDelay: lerp(0.012, 0.032, f), maxDelay: lerp(0.05, 0.12, f), wet: lerp(20, 60, g))
        case .forest:
            // 森林：枝叶把高频吃掉，稀疏、暗的散射尾巴；越远高频掉得越多。
            shelf(units[0], frequency: 6000, gain: lerp(-2, -8, g))
            return reverb(units[1], decay: lerp(0.6, 1.6, f), brightness: 0.2,
                          minDelay: lerp(0.01, 0.03, f), maxDelay: lerp(0.06, 0.16, f), wet: lerp(8, 30, g))
        case .outdoor:
            // 空旷的室外：几乎没有混响；远了高频被空气吃掉，远处墙面给一声很轻的回响（slapback）。
            shelf(units[0], frequency: 5000, gain: lerp(-1, -9, g), lowCut: -2)
            delay(units[1], time: lerp(0.05, 0.18, f), feedback: 5, lowpass: 3000, wet: lerp(6, 20, g))
            return 0.6
        case .valley:
            // 山谷回声：一声声变暗的回声，谷越大隔得越久、回得越多；远了回声更响、更暗。
            let time = lerp(0.25, 0.75, f)
            let feedback = lerp(30, 55, f)
            delay(units[0], time: time, feedback: feedback, lowpass: lerp(5000, 2000, g), wet: lerp(25, 55, g))
            _ = reverb(units[1], decay: 1.2, brightness: 0.35, minDelay: 0.01, maxDelay: 0.05, wet: 12)
            let repeats = log(0.001) / log(feedback / 100)
            return min(maximumTail, time * repeats + 1.2)
        }
    }

    // MARK: 单元的参数（编号见 AudioUnitParameters.h）

    /// 喇叭类的频带：两级二阶高通 + 两级二阶低通（四阶，边缘够陡）+ 一个参量峰。
    private static func speakerEQ(
        _ eq: SceneUnit, low: Double, high: Double, peak: Double, peakGain: Double, peakWidth: Double
    ) {
        let bands: [(type: Double, frequency: Double, gain: Double, width: Double)] = [
            (2, low, 0, 0.5), (2, low, 0, 0.5), (1, high, 0, 0.5), (1, high, 0, 0.5), (0, peak, peakGain, peakWidth),
        ]
        setBands(eq, bands)
    }

    /// 高频搁架（空气、枝叶吃掉的高频），可选再压一点低频。
    private static func shelf(_ eq: SceneUnit, frequency: Double, gain: Double, lowCut: Double = 0) {
        var bands: [(type: Double, frequency: Double, gain: Double, width: Double)] = [(8, frequency, gain, 0.5)]
        if lowCut != 0 { bands.append((7, 150, lowCut, 0.5)) }
        setBands(eq, bands)
    }

    /// AUNBandEQ：每段 1000 旁路、2000 类型、3000 频率、4000 增益、5000 带宽（+ 段号）；其余段旁路。
    private static func setBands(_ eq: SceneUnit, _ bands: [(type: Double, frequency: Double, gain: Double, width: Double)]) {
        eq.set(0, 0)    // 总增益
        for band in 0..<8 {
            let id = AudioUnitParameterID(band)
            guard band < bands.count else {
                eq.set(1000 + id, 1)
                continue
            }
            let spec = bands[band]
            eq.set(2000 + id, spec.type)
            eq.set(3000 + id, spec.frequency)
            eq.set(4000 + id, spec.gain)
            eq.set(5000 + id, spec.width)
            eq.set(1000 + id, 0)
        }
    }

    /// AUDistortion：只用多项式那一级 + 软削波，延时 / 抽样降级 / 环形调制全关，全湿。
    private static func distortion(_ unit: SceneUnit, drive: Double, polynomial: Double, cubic: Double, squared: Double) {
        unit.set(2, 0)          // Delay Mix
        unit.set(5, 0)          // Decimation Mix
        unit.set(13, 0)         // Ring Mod Mix
        unit.set(6, 1)          // Linear Term
        unit.set(7, squared)    // Squared Term
        unit.set(8, cubic)      // Cubic Term
        unit.set(9, polynomial) // Polynomial Mix
        unit.set(14, drive)     // Soft Clip Gain (dB)
        unit.set(15, 100)       // Wet/Dry
    }

    /// AUReverb2：0 干湿、1 增益、2/3 最短 / 最长反射延时、4/5 低频 / 高频衰减、6 反射随机化。返回余音长度。
    private static func reverb(
        _ unit: SceneUnit, decay: Double, brightness: Double, minDelay: Double, maxDelay: Double, wet: Double
    ) -> Double {
        unit.set(0, wet)
        unit.set(1, 0)
        unit.set(2, minDelay)
        unit.set(3, maxDelay)
        unit.set(4, decay)
        unit.set(5, decay * brightness)
        unit.set(6, 1)
        return min(maximumTail, decay * 1.5 + maxDelay)
    }

    /// AUDelay：0 干湿、1 延时（秒）、2 反馈（%）、3 反馈里的低通（Hz）。
    private static func delay(_ unit: SceneUnit, time: Double, feedback: Double, lowpass: Double, wet: Double) {
        unit.set(0, wet)
        unit.set(1, time)
        unit.set(2, feedback)
        unit.set(3, lowpass)
    }

    private static func lerp(_ from: Double, _ to: Double, _ t: Double) -> Double {
        from + (to - from) * min(max(t, 0), 1)
    }
}
