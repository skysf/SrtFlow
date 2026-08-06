// 原生字幕生成 Phase 0 spike（一次性原型，不进产品代码、不接四层自检）。
// 见 docs/plans/2026-08-06-native-subtitle-generation.md 第 16 节 Phase 0 与 17.2 销号清单。
//
// 验证目标：tools-5.9 式「部署目标 macOS 14 + availability 门控」下
// Speech(26+)/Translation(15+) 的编译、弱链接与真机行为。
// 2026-08-06 已用它销号：TCC 无弹窗、词级 audioTimeRange+标点、volatile/final 分流、
// maximumReservedLocales=5、Translation 三态错误面、init(installedSource:) 不抛错、
// Translation 栈依赖主队列（CLI 必须 dispatchMain()，阻塞主线程会挂死 status 查询）。
//
// 编译：swiftc -target arm64-apple-macos14.0 -o spike main.swift   （零告警 = 门控成立）
// 链接检查：otool -L spike | grep -i 'speech\|translation'          （应显示 weak）
// 用法：spike info | spike asr <audiofile> <locale> | spike translate <src> <dst> <text>
// 造测试音频：say -o test.aiff "Hello world. Can it produce punctuation marks?"
import Foundation
import AVFoundation
import CoreMedia
import Speech
import Translation

@available(macOS 26.0, *)
enum SpeechSpike {
    static func info() async {
        print("== SpeechTranscriber runtime facts ==")
        print("isAvailable:", SpeechTranscriber.isAvailable)
        let supported = await SpeechTranscriber.supportedLocales
        let installed = await SpeechTranscriber.installedLocales
        print("supportedLocales (\(supported.count)):", supported.map(\.identifier).sorted().joined(separator: " "))
        print("installedLocales (\(installed.count)):", installed.map(\.identifier).sorted().joined(separator: " "))
        print("maximumReservedLocales:", AssetInventory.maximumReservedLocales)
    }

    static func transcribe(file: String, localeID: String) async {
        let locale = Locale(identifier: localeID)
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )
        do {
            let status = await AssetInventory.status(forModules: [transcriber])
            print("asset status:", status)
            if status != .installed {
                print("reserving + installing model for \(localeID)…")
                _ = try await AssetInventory.reserve(locale: locale)
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    let progressTask = Task {
                        while !Task.isCancelled {
                            print(String(format: "  download %.0f%%", request.progress.fractionCompleted * 100))
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                        }
                    }
                    try await request.downloadAndInstall()
                    progressTask.cancel()
                    print("model installed")
                } else {
                    print("assetInstallationRequest returned nil (nothing to install)")
                }
            }

            let audioFile = try AVAudioFile(forReading: URL(fileURLWithPath: file))
            let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
            print("bestAvailableAudioFormat:", fmt.map(String.init(describing:)) ?? "nil")

            let collector = Task {
                var finalCount = 0, volatileCount = 0
                for try await result in transcriber.results {
                    if result.isFinal {
                        finalCount += 1
                        let plain = String(result.text.characters)
                        print("FINAL  #\(finalCount) range=\(fmtRange(result.range)) finalizedThrough=\(fmtTime(result.resultsFinalizationTime))")
                        print("  text: \"\(plain)\"")
                        for run in result.text.runs {
                            let word = String(result.text[run.range].characters)
                            let tr = run.audioTimeRange.map(fmtRange) ?? "-"
                            let conf = run.transcriptionConfidence.map { String(format: "%.2f", $0) } ?? "-"
                            print("    run \"\(word)\" time=\(tr) conf=\(conf)")
                        }
                    } else {
                        volatileCount += 1
                        print("volatile #\(volatileCount): \"\(String(result.text.characters))\"")
                    }
                }
                print("results stream ended. final=\(finalCount) volatile=\(volatileCount)")
            }

            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let last = try await analyzer.analyzeSequence(from: audioFile)
            print("analyzeSequence done, last sample time:", last.map(fmtTime) ?? "nil")
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            try await collector.value
            await AssetInventory.release(reservedLocale: locale)
        } catch {
            print("ASR spike error:", error)
        }
    }

    static func fmtTime(_ t: CMTime) -> String { String(format: "%.3fs", CMTimeGetSeconds(t)) }
    static func fmtRange(_ r: CMTimeRange) -> String {
        String(format: "[%.3f–%.3f]", CMTimeGetSeconds(r.start), CMTimeGetSeconds(r.end))
    }
}

@available(macOS 15.0, *)
enum TranslationSpike {
    static func run(src: String, dst: String, text: String) async {
        let source = Locale.Language(identifier: src)
        let target = Locale.Language(identifier: dst)
        let availability = LanguageAvailability()
        let status = await availability.status(from: source, to: target)
        print("LanguageAvailability status \(src)→\(dst):", status)
        guard #available(macOS 26.0, *) else {
            print("macOS < 26：CLI 无法拿 session（只能经 SwiftUI translationTask），跳过翻译调用")
            return
        }
        let session = TranslationSession(installedSource: source, target: target)
        print("session created (init 未抛错). canRequestDownloads:", session.canRequestDownloads)
        do {
            let response = try await session.translate(text)
            print("translated: \"\(response.sourceText)\" → \"\(response.targetText)\"")
        } catch {
            print("translate threw:", error)
        }
    }
}

setbuf(stdout, nil)
let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: spike info | spike asr <file> <locale> | spike translate <src> <dst> <text>")
    exit(1)
}
// 用 dispatchMain() 而非信号量：Translation 栈可能依赖主队列被服务，
// 阻塞主线程会把 LanguageAvailability.status 都挂死（本身就是 Phase 0 发现）。
Task {
    switch args[1] {
    case "info":
        if #available(macOS 26.0, *) { await SpeechSpike.info() }
        else { print("Speech 26+ APIs unavailable on this OS") }
    case "asr" where args.count >= 4:
        if #available(macOS 26.0, *) { await SpeechSpike.transcribe(file: args[2], localeID: args[3]) }
        else { print("Speech 26+ APIs unavailable on this OS") }
    case "translate" where args.count >= 5:
        if #available(macOS 15.0, *) { await TranslationSpike.run(src: args[2], dst: args[3], text: args[4]) }
        else { print("Translation 15+ APIs unavailable on this OS") }
    default:
        print("bad args")
    }
    exit(0)
}
dispatchMain()
