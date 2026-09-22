import CoreGraphics
import Foundation
let a = CommandLine.arguments
let x0 = Double(a[1])!, y0 = Double(a[2])!, x1 = Double(a[3])!, y1 = Double(a[4])!
let src = CGEventSource(stateID: .hidSystemState)
func post(_ t: CGEventType, _ p: CGPoint) {
    let e = CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: p, mouseButton: .left)
    e?.post(tap: .cghidEventTap)
}
CGWarpMouseCursorPosition(CGPoint(x: x0, y: y0)); usleep(300_000)
post(.mouseMoved, CGPoint(x: x0, y: y0)); usleep(150_000)
post(.leftMouseDown, CGPoint(x: x0, y: y0)); usleep(250_000)
let steps = 40
for i in 1...steps {
    let t = Double(i) / Double(steps)
    let p = CGPoint(x: x0 + (x1 - x0) * t, y: y0 + (y1 - y0) * t)
    post(.leftMouseDragged, p)
    usleep(60_000)
}
usleep(700_000)
post(.leftMouseUp, CGPoint(x: x1, y: y1))
usleep(400_000)
print("drag done -> \(x1),\(y1)")
