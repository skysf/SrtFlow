import SwiftUI
import AVKit
import SrtFlowCore

/// Owns the AVPlayer and publishes playback time for subtitle sync.
final class PlayerClock: ObservableObject {
    @Published private(set) var time: TimeInterval = 0
    @Published private(set) var hasVideo = false

    let player = AVPlayer()
    private var timeObserver: Any?

    init() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] cmTime in
            self?.time = cmTime.seconds
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }

    func attach(url: URL) {
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        hasVideo = true
        player.play()
    }

    func detach() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        hasVideo = false
        time = 0
    }
}

/// 用 AppKit 原生 AVPlayerView 代替 SwiftUI 的 VideoPlayer：
/// VideoPlayer 走私有框架 _AVKit_SwiftUI，在某些系统版本上实例化即崩溃。
struct PlayerViewRepresentable: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }
}

struct VideoPreviewView: View {
    @ObservedObject var clock: PlayerClock
    let currentCue: SubtitleCue?

    var body: some View {
        VStack(spacing: 8) {
            PlayerViewRepresentable(player: clock.player)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Text(Timecode.formatMillis(clock.time, separator: "."))
                .monospacedDigit()
                .font(.callout)
                .foregroundStyle(.secondary)

            if let cue = currentCue {
                Text(SubtitleSerializer.plainText(cue.text))
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .padding(.horizontal)
            } else {
                Text("—")
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.bottom, 8)
    }
}
