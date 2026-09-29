import AVFoundation
import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - 配旁白：fal 那一档（方案第 42 条最上面一档，第 52 条克隆）
//
// 管什么：add_voiceover 这一次能不能用 fal 的声音（有 Key、这一批字不会让今天超过每日上限、Key 读得出来 —— 三样有一样不行就退到
// 下一档，并在结果里说清楚为什么，因为配旁白是同步的工具，不能停下来问用户）、一句一句让 fal 读、下载下来、
// 过 `AIAudioFileWriter`（音量和文件格式只有一处说了算，同另外两种声音）、把 fal 报的词时间换成字幕认的词；
// 克隆：把用户给的一段素材里的声音截一段当参考音频，交给克隆模型（Zonos2）。
// 不管什么：挑哪个音色（AIVoiceChoice / AIFalVoices）、放上时间线（AIVoiceoverTool）、HTTP（FalClient）。

@MainActor
enum AIFalVoice {
    /// 这一次可以用的 fal：模型、Key。
    struct Offer {
        let model: FalModel
        let key: String
    }

    /// 能用就回 `Offer`；不能用回一句话（给 AI，进结果的 voice.note）。没接 fal（没有 Key）时两个都是 nil：不用提它。
    static func offer(kind: FalModel.Kind, characters: Int) async -> (offer: Offer?, note: String?) {
        let store = FalSettingsStore.shared
        guard store.hasKey else { return (nil, nil) }
        let model = store.model(for: kind)
        let usage = FalUsage(seconds: FalUsage.speechSeconds(characters: characters), characters: characters)
        let estimate = model.estimate(usage)
        let spent = store.spentToday()
        guard FalSpendPolicy.allowsWithoutAsking(estimate: estimate, spentToday: spent, dailyLimit: store.dailyLimit) else {
            let why = estimate.map { "would take today's fal.ai spending to \(FalMoney.text(spent + $0)), over the user's \(FalMoney.text(store.dailyLimit)) daily limit" }
                ?? "has no known price"
            return (nil, "The fal.ai voice \(kind == .voiceClone ? "for cloning " : "")was not used: it \(why). "
                + "The user can raise the limit in SrtFlow → Settings → AI.")
        }
        let hinted = FalPromptFlag()
        let result = await FalKeyCache.shared.key(willAsk: {
            hinted.value = true
            AISession.shared.setHint(L10n("macOS is about to ask whether SrtFlow may use your fal.ai key. Click Always Allow."))
            AITranslationReadiness.bringSrtFlowForward()
        })
        if hinted.value { AISession.shared.setHint(nil) }
        guard case .key(let key) = result else {
            return (nil, "The fal.ai voice was not used: SrtFlow could not read the fal.ai key from the macOS keychain "
                + "(the user has to click Always Allow when macOS asks).")
        }
        return (Offer(model: model, key: key), nil)
    }

    /// 让 fal 读一句，写到 `url`（.m4a）。克隆时给 `reference`（data URI）。
    static func speak(
        _ text: String, voice: String, language: String, wantsWords: Bool, reference: String?, offer: Offer, to url: URL
    ) async throws -> AISpeechSynthesis.Output {
        var request = FalRequest(kind: reference == nil ? .voice : .voiceClone, prompt: text)
        request.voice = voice
        request.language = language
        request.wantsWordTimes = wantsWords
        request.referenceAudioURL = reference
        let body: JSONValue
        do {
            body = try FalInputs.body(request, dialect: FalDialect(endpoint: offer.model.endpoint))
        } catch let error as FalInputError {
            throw AIToolError(error.message)
        }
        let key = offer.key
        let client = FalClient(base: FalClient.configuredBase()) { key }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("SrtFlow-fal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let result: JSONValue
        let downloaded: URL
        do {
            result = try await client.run(endpoint: offer.model.endpoint, body: body, maxSeconds: request.kind.maxSeconds).result
            let media = try FalOutputs.media(from: result, kind: request.kind)
            downloaded = scratch.appendingPathExtension(media.fileExtension)
            try await client.download(media.url, to: downloaded)
        } catch let error as FalError {
            throw AIToolError(error.message)
        } catch let error as FalOutputError {
            throw AIToolError(error.message)
        }
        // 花了钱：记账（估算）。
        let usage = FalUsage(seconds: FalUsage.speechSeconds(characters: text.count), characters: text.count)
        FalSettingsStore.shared.recordSpend(offer.model.estimate(usage) ?? 0)
        defer { try? FileManager.default.removeItem(at: downloaded) }
        let (raw, rate) = try await Task.detached { try decode(downloaded) }.value
        let samples = try AIAudioFileWriter.writeVoiceover(raw, sampleRate: rate, to: url)
        let duration = Double(samples.count) / rate
        let words = AIFalVoices.timedWords(FalOutputs.wordTimes(from: result), text: text, duration: duration)
        return AISpeechSynthesis.Output(url: url, duration: duration, words: words)
    }

    // MARK: 克隆的参考音频

    /// 素材里一段有人声的音频 → WAV 的 data URI（16 kHz 单声道，够克隆用）。整段几乎没声音就说清楚。
    static func referenceSample(from source: URL, start: Double, seconds: Double) async throws -> String {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SrtFlow-clone-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let caf: URL
        do {
            caf = try await AudioWindowReader.extract(
                assetURL: source, range: SourceRange(start: start, end: start + seconds), into: folder, isCancelled: { Task.isCancelled }
            )
        } catch let error as AudioWindowReader.ReadError {
            throw AIToolError(error.message)
        }
        let samples = try await Task.detached { try readInt16(caf) }.value
        let loudest = samples.map { abs(Int32($0)) }.max() ?? 0
        guard samples.count >= Int(AudioWindowReader.sampleRate * 3), loudest > 300 else {
            throw AIToolError("That part of \(source.lastPathComponent) has no speech to clone (start \(Int(start)) s, \(Int(seconds)) s long). "
                + "Pick a stretch where one person talks clearly, for at least 5 seconds.")
        }
        let wav = AIFalVoices.wavData(samples: samples, sampleRate: Int(AudioWindowReader.sampleRate))
        return "data:audio/wav;base64,\(wav.base64EncodedString())"
    }

    // MARK: 解码（在后台线程上做，不占主线程）

    nonisolated private static func decode(_ url: URL) throws -> ([Float], Double) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard file.length > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw AIToolError("fal.ai's voice file was empty.")
        }
        try file.read(into: buffer)
        guard let channels = buffer.floatChannelData else { throw AIToolError("fal.ai's voice file could not be decoded.") }
        let frames = Int(buffer.frameLength), count = max(1, Int(format.channelCount))
        var mono = [Float](repeating: 0, count: frames)
        for channel in 0..<count {
            for index in 0..<frames { mono[index] += channels[channel][index] / Float(count) }
        }
        return (mono, format.sampleRate)
    }

    nonisolated private static func readInt16(_ url: URL) throws -> [Int16] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        guard file.length > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            return []
        }
        try file.read(into: buffer)
        guard let data = buffer.int16ChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
    }
}
