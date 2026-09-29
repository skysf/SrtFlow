import SwiftUI

// MARK: - 设置 → AI 里的「SrtFlow 配音声音」
//
// 管什么：SrtFlow 自己的声音（本机的 Kokoro）下没下：没下载一个「下载」，下载中进度和「停止」，装好了「删除」，失败了原因和
// 「重试」。和 AI 的 `add_voiceover download_voices` 是同一次下载（KokoroVoicePack），AI 下的时候这里照样看得见进度
// （方案第 50 条）。一行只放一个按钮（同上面几个客户端那几行）。
// 不管什么：下载和安装（KokoroVoicePack）。

struct KokoroVoiceSettingsRow: View {
    @ObservedObject private var pack = KokoroVoicePack.shared

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent {
                HStack(spacing: 6) {
                    status
                    action
                }
                .controlSize(.small)
            } label: {
                Text("SrtFlow voices")
            }
            Text("Natural voices for AI voiceovers, made on this Mac, in English, Chinese and 6 more languages. About 333 MB.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if case .downloading(let fraction) = pack.state {
                ProgressView(value: fraction)
                    .controlSize(.small)
            }
        }
        .onAppear { pack.refresh() }
    }

    @ViewBuilder
    private var status: some View {
        switch pack.state {
        case .installed:
            Text("Downloaded").foregroundStyle(.green)
        case .downloading(let fraction):
            Text(verbatim: "\(Int(fraction * 100))%").foregroundStyle(.secondary).monospacedDigit()
        case .failed:
            Text("Download failed").foregroundStyle(.orange)
        case .notInstalled:
            Text("Not downloaded").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var action: some View {
        switch pack.state {
        case .installed:
            Button("Delete") { pack.remove() }
                .instantHelp("Delete SrtFlow's voices from this Mac; AI voiceovers use the Mac's voices until you download them again")
        case .downloading:
            Button("Stop") { pack.cancel() }
                .instantHelp("Stop the download; downloading again continues where it stopped")
        case .failed(let message):
            Button("Try Again") { pack.startInstall() }
                .instantHelp(verbatim: message)
        case .notInstalled:
            Button("Download") { pack.startInstall() }
                .instantHelp("Download SrtFlow's voices (about 333 MB) so AI voiceovers sound natural")
        }
    }
}
