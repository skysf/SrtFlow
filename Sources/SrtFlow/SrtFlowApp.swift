import SwiftUI
import SrtFlowCore

@main
struct SrtFlowApp: App {
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        DocumentGroup(newDocument: { SubtitleDocument() }) { file in
            ContentView(document: file.document)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Batch Convert…") { openWindow(id: "batch-convert") }
                    .keyboardShortcut("b", modifiers: [.command])
            }
        }

        Window("Batch Convert", id: "batch-convert") {
            BatchConvertView()
        }
        .defaultSize(width: 600, height: 440)
    }
}
