import AppKit

var logPath = "/tmp/dragsource.log"
func dslog(_ m: String) {
    let line = "\(Date()) \(m)\n"
    if let h = FileHandle(forWritingAtPath: logPath) {
        h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
    } else {
        try? Data(line.utf8).write(to: URL(fileURLWithPath: logPath))
    }
}

final class DragView: NSView, NSDraggingSource {
    var url: URL!
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ r: NSRect) {
        NSColor.systemOrange.setFill(); bounds.fill()
        ("DRAG ME" as NSString).draw(at: NSPoint(x: 20, y: 60),
            withAttributes: [.font: NSFont.boldSystemFont(ofSize: 18), .foregroundColor: NSColor.black])
    }
    override func mouseDown(with event: NSEvent) { dslog("mouseDown") }
    override func mouseDragged(with event: NSEvent) {
        dslog("mouseDragged -> beginDraggingSession")
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let img = NSImage(size: NSSize(width: 48, height: 48))
        img.lockFocus(); NSColor.systemBlue.setFill(); NSRect(x: 0, y: 0, width: 48, height: 48).fill(); img.unlockFocus()
        item.setDraggingFrame(NSRect(x: 0, y: 0, width: 48, height: 48), contents: img)
        beginDraggingSession(with: [item], event: event, source: self)
    }
    func draggingSession(_ s: NSDraggingSession, sourceOperationMaskFor c: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ s: NSDraggingSession, willBeginAt p: NSPoint) { dslog("session willBegin at \(p)") }
    func draggingSession(_ s: NSDraggingSession, endedAt p: NSPoint, operation o: NSDragOperation) {
        dslog("session ended at \(p) op=\(o.rawValue)")
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let file = URL(fileURLWithPath: CommandLine.arguments[1])
let originX = Double(CommandLine.arguments[2])!
let originY = Double(CommandLine.arguments[3])!
logPath = CommandLine.arguments[4]
dslog("launched with \(file.lastPathComponent)")
let win = NSWindow(contentRect: NSRect(x: originX, y: originY, width: 200, height: 140),
                   styleMask: [.titled], backing: .buffered, defer: false)
win.title = "DragSource"
let v = DragView(frame: NSRect(x: 0, y: 0, width: 200, height: 140))
v.url = file
win.contentView = v
win.makeKeyAndOrderFront(nil)
win.level = .floating
app.activate(ignoringOtherApps: true)
app.run()
