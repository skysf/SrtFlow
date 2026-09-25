import AudioToolbox
import AVFoundation
import os

// MARK: - 声音场景的声音怎么算：macOS 自带的效果单元
//
// 每种场景是一串苹果自带的效果单元（AUNBandEQ / AUDistortion / AUReverb2 / AUDelay），用
// `AudioUnitRender` 直接驱动。2026-09-24 探针定的路（docs/plans/2026-09-24-sound-scenes.md 第三节）：
// 在 tap 里跑、实时和离线**逐位相同**、分块大小不影响结果、延迟为 0；AVAudioEngine 那条路单声道
// 会崩、AVAudioUnitReverb 包的是不支持单声道的 MatrixReverb，所以用裸的单元。
//
// 这个文件只管「一串单元怎么搭、旋钮怎么换算成参数」：
// - `SceneUnit`：一个效果单元的薄包装（按处理格式建、设参数、渲染一块、复位）；
// - `SceneChain`：一种场景的一串单元 + 两个旋钮到参数的换算 + 余音多长；
// - `SceneLoudness`：响度补偿，用**同一串处理**量出来。
// 每段声音在合成音轨上怎么路由、增益怎么乘在 VideoEditSoundSceneTrack.swift。

/// 非交错的 f32 缓冲（每个声道一块），效果单元的输入输出都用它。
final class SceneBuffers {
    let channels: Int
    let capacity: Int
    let list: UnsafeMutableAudioBufferListPointer

    init(channels: Int, capacity: Int) {
        self.channels = max(1, channels)
        self.capacity = max(1, capacity)
        list = AudioBufferList.allocate(maximumBuffers: self.channels)
        for index in 0..<self.channels {
            let data = UnsafeMutablePointer<Float>.allocate(capacity: self.capacity)
            data.initialize(repeating: 0, count: self.capacity)
            list[index] = AudioBuffer(
                mNumberChannels: 1, mDataByteSize: UInt32(self.capacity * 4), mData: UnsafeMutableRawPointer(data)
            )
        }
    }

    deinit {
        for index in 0..<channels { list[index].mData?.deallocate() }
        free(list.unsafeMutablePointer)
    }

    func channel(_ index: Int) -> UnsafeMutablePointer<Float> {
        list[min(index, channels - 1)].mData!.assumingMemoryBound(to: Float.self)
    }

    /// 渲染前把每块的字节数设成这一次的帧数（效果单元按它认帧数）。
    func setFrames(_ frames: Int) {
        for index in 0..<channels { list[index].mDataByteSize = UInt32(frames * 4) }
    }
}

/// 一个效果单元：按处理格式建好、设参数、从 `input` 渲染到 `output`、复位。
final class SceneUnit {
    private let unit: AudioUnit
    fileprivate var input: SceneBuffers?
    private var sampleTime: Float64 = 0

    init?(subType: OSType, format: AudioStreamBasicDescription, maxFrames: Int) {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: subType,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else { return nil }
        var instance: AudioUnit?
        guard AudioComponentInstanceNew(component, &instance) == noErr, let instance else { return nil }
        unit = instance
        var streamFormat = format
        var frames = UInt32(maxFrames)
        let formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var callback = AURenderCallbackStruct(
            inputProc: sceneUnitInput, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        guard AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                                   &streamFormat, formatSize) == noErr,
              AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0,
                                   &streamFormat, formatSize) == noErr,
              AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                                   &frames, UInt32(MemoryLayout<UInt32>.size)) == noErr,
              AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                                   &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)) == noErr,
              AudioUnitInitialize(unit) == noErr
        else {
            // 属性都已经初始化了：返回 nil 之后 deinit 照样会跑、会把它释放掉，这里别再释放一次。
            return nil
        }
    }

    deinit {
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }

    func set(_ parameter: AudioUnitParameterID, _ value: Double) {
        AudioUnitSetParameter(unit, parameter, kAudioUnitScope_Global, 0, Float(value), 0)
    }

    func reset() {
        AudioUnitReset(unit, kAudioUnitScope_Global, 0)
    }

    /// 从 `input` 渲染 `frames` 帧到 `output`（两块不许是同一块）。
    func render(from input: SceneBuffers, into output: SceneBuffers, frames: Int) -> Bool {
        self.input = input
        output.setFrames(frames)
        var flags = AudioUnitRenderActionFlags()
        var stamp = AudioTimeStamp()
        stamp.mSampleTime = sampleTime
        stamp.mFlags = .sampleTimeValid
        sampleTime += Float64(frames)
        return AudioUnitRender(unit, &flags, &stamp, 0, UInt32(frames), output.list.unsafeMutablePointer) == noErr
    }
}

/// 效果单元来要输入时，把 `SceneUnit.input` 那一块抄给它（它给的是自己的输入缓冲，或者要我们给指针）。
private let sceneUnitInput: AURenderCallback = { refCon, _, _, _, frames, ioData in
    let unit = Unmanaged<SceneUnit>.fromOpaque(refCon).takeUnretainedValue()
    guard let source = unit.input, let ioData else { return noErr }
    let target = UnsafeMutableAudioBufferListPointer(ioData)
    let bytes = Int(frames) * 4
    for index in 0..<target.count {
        let from = UnsafeMutableRawPointer(source.channel(index))
        if let data = target[index].mData {
            data.copyMemory(from: from, byteCount: bytes)
        } else {
            target[index].mData = from
        }
        target[index].mDataByteSize = UInt32(bytes)
    }
    return noErr
}

// MARK: - 一种场景的一串单元

/// 一种场景的一串效果单元。一段声音一份（各段的余音各自散），由 `SceneTrackRenderer` 管着。
final class SceneChain {
    let kind: SoundSceneKind
    let maxFrames: Int
    private let units: [SceneUnit]
    private let first: SceneBuffers
    private let second: SceneBuffers
    /// 调用方把这一块的输入写进这里（每个声道 `maxFrames` 帧）。
    var input: SceneBuffers { first }
    /// 输入停了之后还要再渲染多久（余音散完）；跟着旋钮变。
    private(set) var tailSeconds = 0.1

    init?(kind: SoundSceneKind, format: AudioStreamBasicDescription, maxFrames: Int) {
        let subTypes = SceneRecipe.units(for: kind)
        var built: [SceneUnit] = []
        for subType in subTypes {
            guard let unit = SceneUnit(subType: subType, format: format, maxFrames: maxFrames) else { return nil }
            built.append(unit)
        }
        self.kind = kind
        self.maxFrames = maxFrames
        units = built
        first = SceneBuffers(channels: Int(format.mChannelsPerFrame), capacity: maxFrames)
        second = SceneBuffers(channels: Int(format.mChannelsPerFrame), capacity: maxFrames)
    }

    /// 把场景的两个旋钮换算成各单元的参数（主线程调；单元的参数写入本身是线程安全的）。
    func apply(_ scene: SoundScene) {
        tailSeconds = SceneRecipe.configure(units, kind: kind, first: scene.first, second: scene.second)
    }

    func reset() {
        units.forEach { $0.reset() }
    }

    /// 把 `input` 里的 `frames` 帧过一遍整串单元，返回结果所在的那一块。失败时返回 nil（调用方走原声）。
    func render(frames: Int) -> SceneBuffers? {
        guard frames > 0, frames <= maxFrames else { return nil }
        var from = first
        var to = second
        for unit in units {
            guard unit.render(from: from, into: to, frames: frames) else { return nil }
            swap(&from, &to)
        }
        return from
    }
}

// MARK: - 响度补偿

/// 换来换去不忽大忽小：场景输出乘上这个数，和进去的声音一样响。**用同一串处理量出来**
/// （48kHz 立体声、1.2 秒语音样的噪声，量后一半的 RMS），按场景和两个旋钮（取到 1%）缓存。
enum SceneLoudness {
    private static let cache = OSAllocatedUnfairLock(initialState: [String: Float]())

    static func compensation(for scene: SoundScene) -> Float {
        let key = "\(scene.kind.rawValue)|\(Int((scene.first * 100).rounded()))|\(Int((scene.second * 100).rounded()))"
        if let cached = cache.withLock({ $0[key] }) { return cached }
        let measured = measure(scene)
        cache.withLock { $0[key] = measured }
        return measured
    }

    private static func measure(_ scene: SoundScene) -> Float {
        let block = 4096
        let format = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2,
            mBitsPerChannel: 32, mReserved: 0
        )
        guard let chain = SceneChain(kind: scene.kind, format: format, maxFrames: block) else { return 1 }
        chain.apply(scene)
        // 按常见人声的电平量（−20 dBFS RMS）：喇叭类的削波跟着电平走，量得太轻或太响都会偏。
        var noise = SpeechNoise()
        let total = 57_600    // 1.2 秒
        var signal = (0..<total).map { _ in noise.next() }
        let level = (signal.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(total)).squareRoot()
        let scale = Float(0.1 / max(level, 1e-9))
        signal = signal.map { $0 * scale }
        var inEnergy = 0.0
        var outEnergy = 0.0
        var done = 0
        while done < total {
            let frames = min(block, total - done)
            let measured = done >= total / 2
            for index in 0..<frames {
                let value = signal[done + index]
                chain.input.channel(0)[index] = value
                chain.input.channel(1)[index] = value
                // 输入的能量**渲染之前**记：串了两个单元的链会把输入那一块写成输出。
                if measured { inEnergy += 2 * Double(value) * Double(value) }
            }
            guard let output = chain.render(frames: frames) else { return 1 }
            if measured {
                for index in 0..<frames {
                    let l = Double(output.channel(0)[index])
                    let r = Double(output.channel(1)[index])
                    outEnergy += l * l + r * r
                }
            }
            done += frames
        }
        guard outEnergy > 0 else { return 1 }
        return Float(min(max((inEnergy / outEnergy).squareRoot(), 0.25), 4))
    }
}

/// 语音样的噪声：粉红噪声（Paul Kellet 的滤波器）再高通 100Hz、低通 4kHz，确定性的（固定种子）。
private struct SpeechNoise {
    private var seed: UInt32 = 0x1234_5678
    private var b0 = 0.0, b1 = 0.0, b2 = 0.0, b3 = 0.0, b4 = 0.0, b5 = 0.0, b6 = 0.0
    private var highpass = 0.0, lastPink = 0.0, lowpass = 0.0

    mutating func next() -> Float {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        let white = Double(seed) / Double(UInt32.max) * 2 - 1
        b0 = 0.99886 * b0 + white * 0.0555179
        b1 = 0.99332 * b1 + white * 0.0750759
        b2 = 0.96900 * b2 + white * 0.1538520
        b3 = 0.86650 * b3 + white * 0.3104856
        b4 = 0.55000 * b4 + white * 0.5329522
        b5 = -0.7616 * b5 - white * 0.0168980
        let pink = (b0 + b1 + b2 + b3 + b4 + b5 + b6 + white * 0.5362) * 0.11
        b6 = white * 0.115926
        highpass = 0.987 * (highpass + pink - lastPink)     // ≈ 100Hz @48k
        lastPink = pink
        lowpass += 0.41 * (highpass - lowpass)              // ≈ 4kHz @48k
        return Float(lowpass * 0.5)
    }
}
