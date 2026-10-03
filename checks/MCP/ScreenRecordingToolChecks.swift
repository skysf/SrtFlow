import CoreGraphics
import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// record_screen（2026-10-03，docs/plans/2026-10-03-screen-recording-mcp.md）的纯值规则：
// - 参数怎么读（AIScreenRecordingRequest）：默认值、每个参数的范围、只属于某种来源的参数给到别处当场报错；
// - 来源怎么挑（AIScreenSourceMatch）：能录的窗口、窗口编号 > App 名一样 > App 名里有 > 标题里有、同一档挑最前面的；
//   屏幕编号主屏 1、其余从左到右；区域的比例换成显示器上的点（取整、夹进屏内、太小报错）；麦克风按名字挑；
// - 词表和 App 的类型对账（区域比例 = RegionAspectRatio、指针、状态的说法），工具的定义（必填、枚举、会删东西、get_status 的 screen）。
// 真录要真屏幕和授权：靠 docs/architecture/ai-control-mcp.md 第八节的人工回归清单。

func runScreenRecordingToolChecks() {
    checkRecordingRequestDefaults()
    checkRecordingRequestSources()
    checkRecordingRequestOptions()
    checkRecordingWords()
    checkWindowPicking()
    checkDisplaysAndRegions()
    checkMicrophonePicking()
    checkRecordScreenDefinition()
}

private func request(_ object: [String: JSONValue]) throws -> AIScreenRecordingRequest {
    try AIScreenRecordingRequest.parse(args(object))
}

// MARK: - 参数

private func checkRecordingRequestDefaults() {
    guard let start = try? request(["action": "start"]) else { return check(false, "action=start alone is a valid request") }
    checkEqual(start.source, .display(nil), "the default source is the main display")
    check(start.computerAudio, "computer audio is on by default (like the Record Screen sheet)")
    check(start.microphone == nil, "the microphone is off unless asked")
    checkEqual(start.cursor, CursorConfiguration.default, "the pointer shows, clicks are not highlighted")
    checkEqual(start.countdown, 3, "the countdown is 3 seconds, like a manual recording")
    check(start.duration == nil && start.title == nil, "no duration, default name")
    check(start.addsToTimeline, "it lands on the timeline by default")

    checkThrows("action is required") { _ = try request([:]) }
    checkThrows("an unknown action is refused") { _ = try request(["action": "pause"]) }
    checkEqual(try? request(["action": "stop", "source": "window"]).action, .stop, "stop ignores start's parameters")
    checkThrows("resolve needs a decision") { _ = try request(["action": "resolve"]) }
    checkThrows("resolve's decision is add, keep or discard") { _ = try request(["action": "resolve", "decision": "delete"]) }
    checkEqual(try? request(["action": "resolve", "decision": "discard"]).decision, .discard, "resolve carries the decision")
}

private func checkRecordingRequestSources() {
    checkEqual(try? request(["action": "start", "display": 2]).source, .display(2), "display alone picks a display")
    checkThrows("display counts from 1") { _ = try request(["action": "start", "display": 0]) }
    checkEqual(try? request(["action": "start", "source": "window", "window": "  Safari "]).source, .window("Safari"), "window text is trimmed")
    checkThrows("source=window needs window") { _ = try request(["action": "start", "source": "window"]) }
    checkThrows("window with source=display is refused (not silently recording the whole screen)") {
        _ = try request(["action": "start", "window": "Safari"])
    }
    checkThrows("display does not go with window") { _ = try request(["action": "start", "source": "window", "window": "Notes", "display": 1]) }

    let rect: JSONValue = ["x": 0.25, "y": 0.1, "width": 0.5, "height": 0.5]
    checkEqual(try? request(["action": "start", "source": "region", "rect": rect, "display": 2]).source,
               .region(display: 2, fractions: CGRect(x: 0.25, y: 0.1, width: 0.5, height: 0.5)), "region carries its fractions and display")
    checkThrows("source=region needs rect") { _ = try request(["action": "start", "source": "region"]) }
    checkThrows("rect with source=display is refused") { _ = try request(["action": "start", "rect": rect]) }
    checkThrows("rect must be an object") { _ = try request(["action": "start", "source": "region", "rect": "0,0,1,1"]) }
    checkThrows("rect needs all four numbers") { _ = try request(["action": "start", "source": "region", "rect": ["x": 0, "y": 0, "width": 1]]) }
    for bad: JSONValue in [["x": -0.1, "y": 0, "width": 0.5, "height": 0.5], ["x": 0, "y": 0, "width": 0, "height": 0.5],
                           ["x": 0.6, "y": 0, "width": 0.5, "height": 0.5], ["x": 0, "y": 0.7, "width": 0.5, "height": 0.5]] {
        checkThrows("rect outside the display is refused, not clamped: \(bad.encodedString())") {
            _ = try request(["action": "start", "source": "region", "rect": bad])
        }
    }
    // 舍入的误差（0.3 + 0.7 = 1.0000000000000002）照收、夹回 1。
    if case .region(_, let fractions)? = try? request(["action": "start", "source": "region", "rect": ["x": 0.3, "y": 0, "width": 0.7000004, "height": 1]]).source {
        check(fractions.maxX <= 1, "a hair over 1 is clamped back to the edge")
    } else {
        check(false, "a rect a hair over the edge is accepted")
    }

    checkEqual(try? request(["action": "start", "source": "drag", "ratio": "9:16"]).source, .drag(ratio: .tall9x16), "drag carries the ratio")
    checkEqual(try? request(["action": "start", "source": "drag"]).source, .drag(ratio: .free), "drag without ratio is free")
    checkThrows("ratio only goes with drag") { _ = try request(["action": "start", "ratio": "16:9"]) }
    checkThrows("display does not go with drag (the user picks the display by dragging)") {
        _ = try request(["action": "start", "source": "drag", "display": 1])
    }
}

private func checkRecordingRequestOptions() {
    let full = try? request([
        "action": "start", "computer_audio": false, "microphone": "MacBook", "pointer": "clicks", "countdown": 0,
        "duration": 30, "title": "Demo.mov", "add_to_timeline": false
    ])
    check(full?.computerAudio == false, "computer_audio=false")
    checkEqual(full?.microphone, "MacBook", "a microphone name is kept as given")
    checkEqual(full?.cursor, CursorConfiguration(showsCursor: true, showsClicks: true), "pointer=clicks shows the pointer and the clicks")
    checkEqual(full?.countdown, 0, "countdown=0 starts at once (when the AI operates the Mac itself)")
    checkEqual(full?.duration, 30, "duration")
    checkEqual(full?.title, "Demo", "the title drops a typed .mov")
    check(full?.addsToTimeline == false, "add_to_timeline=false keeps only the file")

    checkEqual(try? request(["action": "start", "pointer": "hidden"]).cursor, CursorConfiguration(showsCursor: false, showsClicks: false), "pointer=hidden")
    checkEqual(try? request(["action": "start", "microphone": true]).microphone, "default", "microphone=true is the default microphone")
    for off: JSONValue in [false, "off", "none", "  "] {
        check((try? request(["action": "start", "microphone": off]))?.microphone == nil, "microphone=\(off.encodedString()) records none")
    }
    checkEqual(try? request(["action": "start", "microphone": "Default"]).microphone, "default", "Default is the default microphone")
    checkThrows("countdown above 10 is refused") { _ = try request(["action": "start", "countdown": 11]) }
    checkThrows("a negative countdown is refused") { _ = try request(["action": "start", "countdown": -1]) }
    checkThrows("duration under a second is refused") { _ = try request(["action": "start", "duration": 0.5]) }
    checkThrows("duration over four hours is refused") { _ = try request(["action": "start", "duration": 14_401]) }
    checkEqual(try? request(["action": "start", "title": "a/b: c"]).title, "a-b- c", "slashes and colons in the title are made safe")
    check((try? request(["action": "start", "title": "   "]))?.title == nil, "an empty title means the default name")
}

private func checkRecordingWords() {
    checkEqual(MCPVocabulary.recordingRatios, RegionAspectRatio.allCases.map(AIScreenRecordingWords.word(for:)),
               "the ratio vocabulary is the region sheet's ratios")
    for ratio in RegionAspectRatio.allCases {
        checkEqual(AIScreenRecordingWords.ratio(AIScreenRecordingWords.word(for: ratio)), ratio, "ratio \(ratio) round-trips")
    }
    checkEqual(MCPVocabulary.recordingActions, ["start", "stop", "resolve"], "actions")
    checkEqual(MCPVocabulary.recordingDecisions.compactMap(AIScreenRecordingRequest.Decision.init(rawValue:)).count, 3,
               "every decision word is a Decision")
    checkEqual(Set(MCPVocabulary.recordingPointers.map { AIScreenRecordingWords.cursor($0) }).count, 3, "the three pointer words differ")
    let sample = ScreenRecordingResult(mainURL: media, duration: 1, pixelSize: .zero, frameRate: .fallback)
    let named: [(ScreenRecordingState, String)] = [
        (.idle, "idle"), (.finished(sample), "idle"), (.failed(.pickerCancelled), "idle"), (.configuring, "preparing"),
        (.choosingSource, "choosing_source"), (.countingDown(remaining: 2), "counting_down"), (.starting, "starting"),
        (.recording(startedAt: Date()), "recording"), (.stopping, "finishing"), (.importing, "finishing"),
        (.partialRecovery(sample), "waiting_for_decision")
    ]
    for (state, word) in named { checkEqual(AIScreenRecordingWords.state(state), word, "state \(state) is called \(word)") }
}

// MARK: - 来源

private typealias Window = AIScreenSourceMatch.Window

private func window(_ id: UInt32, _ app: String, _ title: String = "", size: CGFloat = 800, layer: Int = 0, shareable: Bool = true) -> Window {
    Window(id: id, app: app, title: title, frame: CGRect(x: 0, y: 0, width: size, height: size * 0.6), layer: layer, shareable: shareable)
}

private func checkWindowPicking() {
    // 从前到后：菜单栏、SrtFlow 的浮窗（不能被录）、一个小工具条、两个 Safari、Notes、Chrome 里开着一页标题带 Safari 的。
    let windows = [
        window(1, "Window Server", "Menubar", layer: 25), window(2, "SrtFlow", "", shareable: false), window(3, "Notes", "", size: 40),
        window(10, "Safari", "Apple"), window(11, "Safari", "News"), window(12, "Notes", "Shopping list"),
        window(13, "Google Chrome", "Why Safari is fast")
    ]
    checkEqual(AIScreenSourceMatch.recordable(windows).map(\.id), [10, 11, 12, 13], "only normal, shareable, big-enough windows")
    checkEqual(try? AIScreenSourceMatch.pickWindow("safari", among: windows).id, 10, "app name, the frontmost of several")
    checkEqual(try? AIScreenSourceMatch.pickWindow("chrome", among: windows).id, 13, "a word of the app name")
    checkEqual(try? AIScreenSourceMatch.pickWindow("shopping", among: windows).id, 12, "a word of the title")
    checkEqual(try? AIScreenSourceMatch.pickWindow("News", among: windows).id, 11, "the title picks the second Safari window")
    checkEqual(try? AIScreenSourceMatch.pickWindow("11", among: windows).id, 11, "a window number from get_status")
    checkEqual(try? AIScreenSourceMatch.pickWindow("#13", among: windows).id, 13, "a number with #")
    checkThrows("a number that is not on screen") { _ = try AIScreenSourceMatch.pickWindow("2", among: windows) }
    checkThrows("nothing matches") { _ = try AIScreenSourceMatch.pickWindow("Figma", among: windows) }
    // App 名一样的排在标题里有的前面：「Safari」挑 Safari 自己的窗口，不挑标题里提到 Safari 的 Chrome。
    checkEqual(try? AIScreenSourceMatch.pickWindow("Safari", among: [windows[6], windows[3]]).id, 10, "app name beats a title mention")
    // 没授权时标题是空的：空标题不算「标题里有」。
    checkEqual(try? AIScreenSourceMatch.pickWindow("notes", among: [window(20, "Notes", "")]).id, 20, "app name still works without titles")
}

private typealias Display = AIScreenSourceMatch.Display

private func display(_ id: UInt32, _ frame: CGRect, main: Bool = false) -> Display {
    Display(id: id, name: "Display \(id)", frame: frame, pixelSize: CGSize(width: frame.width * 2, height: frame.height * 2), isMain: main)
}

private func checkDisplaysAndRegions() {
    // 本机这种摆法：主屏在 (0,0)，副屏在左上方（负原点），再假想一块在右边。
    let builtIn = display(1, CGRect(x: 0, y: 0, width: 1440, height: 900), main: true)
    let leftAbove = display(2, CGRect(x: -279, y: -1080, width: 1920, height: 1080))
    let right = display(3, CGRect(x: 1440, y: 0, width: 1920, height: 1080))
    let all = [right, leftAbove, builtIn]
    checkEqual(AIScreenSourceMatch.numbered(all).map(\.id), [1, 2, 3], "the main display is 1, then left to right")
    checkEqual(try? AIScreenSourceMatch.pickDisplay(nil, among: all).id, 1, "no number = the main display")
    checkEqual(try? AIScreenSourceMatch.pickDisplay(3, among: all).id, 3, "display 3")
    checkThrows("display 4 does not exist") { _ = try AIScreenSourceMatch.pickDisplay(4, among: all) }
    checkThrows("no displays at all") { _ = try AIScreenSourceMatch.pickDisplay(nil, among: []) }

    let half = CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
    checkEqual(try? AIScreenSourceMatch.localRect(fractions: half, display: builtIn), CGRect(x: 720, y: 450, width: 720, height: 450),
               "the bottom-right quarter of the main display, in display-local points")
    // 负原点的副屏：sourceRect 是相对这块屏左上角的，和它在全局的位置无关（录屏复审 P1-6 那一类坑）。
    let local = try? AIScreenSourceMatch.localRect(fractions: half, display: leftAbove)
    checkEqual(local, CGRect(x: 960, y: 540, width: 960, height: 540), "display-local on a negative-origin display")
    if let local {
        check(ScreenRecordingCoordinateMapper.isWithinDisplay(
            local, display: .init(boundsInPoints: leftAbove.frame, pixelSize: leftAbove.pixelSize)
        ), "the region lies inside that display")
    }
    checkEqual((try? AIScreenSourceMatch.localRect(fractions: CGRect(x: 0.1004, y: 0, width: 0.3, height: 0.5), display: builtIn))?.minX, 145,
               "edges round to whole points")
    checkThrows("a region under 64 points is refused, like the drag sheet") {
        _ = try AIScreenSourceMatch.localRect(fractions: CGRect(x: 0, y: 0, width: 0.02, height: 0.5), display: builtIn)
    }
}

private func checkMicrophonePicking() {
    let devices = [
        AIScreenSourceMatch.Microphone(id: "teams", name: "Microsoft Teams Audio"),
        AIScreenSourceMatch.Microphone(id: "builtin", name: "MacBook Pro Microphone"),
        AIScreenSourceMatch.Microphone(id: "usb", name: "USB Microphone")
    ]
    checkEqual(try? AIScreenSourceMatch.pickMicrophone("default", among: devices, defaultID: "builtin").id, "builtin", "default = the system default")
    checkEqual(try? AIScreenSourceMatch.pickMicrophone("default", among: devices, defaultID: nil).id, "teams", "no default known = the first")
    checkEqual(try? AIScreenSourceMatch.pickMicrophone("usb microphone", among: devices, defaultID: nil).id, "usb", "an exact name")
    checkEqual(try? AIScreenSourceMatch.pickMicrophone("macbook", among: devices, defaultID: nil).id, "builtin", "a word of the name")
    checkThrows("no such microphone") { _ = try AIScreenSourceMatch.pickMicrophone("Rode", among: devices, defaultID: nil) }
    checkThrows("no microphone at all") { _ = try AIScreenSourceMatch.pickMicrophone("default", among: [], defaultID: nil) }
}

// MARK: - 定义

private func checkRecordScreenDefinition() {
    let definition = MCPToolName.recordScreen.definition
    check(MCPToolName.recordScreen.provider == nil, "record_screen is always listed (it needs no provider)")
    check(!definition.readOnly && definition.destructive && !definition.openWorld, "writes files, can discard a leftover, stays on this Mac")
    let schema = definition.inputSchema
    checkEqual(schema["required"]?.arrayValue?.compactMap(\.stringValue), ["action"], "only action is required")
    let properties = schema["properties"]?.objectValue ?? [:]
    checkEqual(Set(properties.keys), [
        "action", "source", "display", "window", "rect", "ratio", "computer_audio", "microphone", "pointer", "countdown",
        "duration", "title", "add_to_timeline", "decision", "confirm_token"
    ], "the parameters")
    for (name, words) in [("action", MCPVocabulary.recordingActions), ("source", MCPVocabulary.recordingSources),
                          ("ratio", MCPVocabulary.recordingRatios), ("pointer", MCPVocabulary.recordingPointers),
                          ("decision", MCPVocabulary.recordingDecisions)] {
        checkEqual(properties[name]?["enum"]?.arrayValue?.compactMap(\.stringValue), words, "\(name) lists its choices")
    }
    checkEqual(properties["rect"]?["required"]?.arrayValue?.compactMap(\.stringValue), ["x", "y", "width", "height"], "rect needs all four")
    checkEqual(properties["countdown"]?["maximum"]?.doubleValue, Double(AIScreenRecordingRequest.maxCountdown), "countdown's range")
    checkEqual(properties["duration"]?["maximum"]?.doubleValue, AIScreenRecordingRequest.maxDuration, "duration's range")
    let text = definition.description
    for word in ["get_status screen=true", "bottom left", "do not click there", "action=stop", "duration", "get_job", "clip ids",
                 "Screen & System Audio Recording", "asks the user once", "30 days", "action=resolve", "set_canvas fps"] {
        check(text.contains(word), "the description says \(word)")
    }
    let status = MCPToolName.getStatus.definition
    checkEqual(status.inputSchema["properties"]?["screen"]?["type"]?.stringValue, "boolean", "get_status takes screen=true")
    check(status.readOnly && status.description.contains("screen recording"), "get_status stays read-only and mentions screen recording")
}
