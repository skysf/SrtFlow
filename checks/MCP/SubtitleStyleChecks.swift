import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// 字幕长什么样（edit_subtitles / burn_subtitles 的 style，方案第 54 条）：参数先全验过；落到工程上只改工程自己的样式、
// 给了位置就收掉拖框的布局、只给字号就把倍率归一；逐词高亮的开关、颜色、倍数；落到一批烧录上时描边 / 底条互换；
// 回给 AI 看的样子；小程序抄的位置词表和 App 对账。编法见 scripts/check-mcp.sh。

func runSubtitleStyleChecks() {
    styleParsing()
    styleOnProject()
    styleForBurnBatch()
}

private func change(_ object: [String: JSONValue]) throws -> AISubtitleStyleChange? {
    try AISubtitleStyleChange(AIToolArguments(.object(["style": .object(object)])))
}

private func styleParsing() {
    checkEqual(MCPVocabulary.subtitlePositions, AISubtitleStyleChange.positions.map(\.name), "style：小程序的位置词表 = App 认的")
    let full = try? change([
        "position": "top", "margin": 0.1, "size": 72, "color": "#FFD400", "box": "#00000099",
        "highlight": "#00E5FF", "highlight_scale": 1.2
    ])
    checkEqual(full?.position, .topCenter, "style：top 是上面居中")
    checkEqual(full?.margin, 108, "style：margin 按画面高的比例换成 1080 基准像素")
    checkEqual(full?.size, 72, "style：字号")
    checkEqual(full?.box, .some(SubtitleColor(red: 0, green: 0, blue: 0, opacity: 0x99 / 255.0)), "style：底条带透明度")
    checkEqual(full?.highlightScale, 1.2, "style：高亮的放大倍数")
    checkEqual(try? change([:]).map { $0 == AISubtitleStyleChange() }, true, "style：空对象不改任何东西")
    checkThrows("style：认不出的位置报错") { _ = try change(["position": "left"]) }
    checkThrows("style：字号超出 20–140 报错") { _ = try change(["size": 200]) }
    checkThrows("style：描边和底条都给颜色报错（底条代替描边）") { _ = try change(["outline": "#000000", "box": "#00000099"]) }
    checkThrows("style：阴影和底条都给报错（阴影跟描边走）") { _ = try change(["shadow": "#000000B3", "box": "#00000099"]) }
    checkThrows("style：字色不能是 none") { _ = try change(["color": "none"]) }
    checkThrows("style：放大超过 1.3 报错") { _ = try change(["highlight_scale": 2]) }
    checkThrows("style：style 不是对象报错") { _ = try AISubtitleStyleChange(AIToolArguments(.object(["style": "big"]))) }
    let fonts = ["Hiragino Sans GB", "Helvetica Neue"]
    checkEqual(try? change(["font": "hiragino sans gb"])?.resolvingFont(in: fonts).font, "Hiragino Sans GB", "style：字体名不分大小写、回表里的写法")
    checkThrows("style：烧录用不了的字体报错（苹方这种读不到文件的）") { _ = try change(["font": "PingFang SC"])?.resolvingFont(in: fonts) }
}

private func styleOnProject() {
    let appWide = BurnInStyle.default
    var state = TimelineState()
    state.subtitleLayout = SubtitleLayout(marginLeft: 100, marginRight: 100, marginBottom: 40, fontScale: 1.5)
    try? change(["size": 70])?.apply(to: &state, appWide: appWide)
    checkEqual(state.subtitleStyle(appWide: appWide).fontSize, 70, "工程：给了字号就改工程自己的样式")
    checkEqual(state.subtitleLayout?.fontScale, 1, "工程：只给字号时拖框的布局留着、字号倍率归一（出来就是这个字号）")
    checkEqual(appWide, BurnInStyle.default, "工程：烧录页记住的那套不动")
    try? change(["position": "top", "margin": 0.08])?.apply(to: &state, appWide: appWide)
    check(state.subtitleLayout == nil && state.translationLayout == nil, "工程：给了位置就收掉拖框的布局（它锚定在底部，会盖住位置）")
    checkEqual(state.subtitleStyle(appWide: appWide).position, .topCenter, "工程：位置")
    checkEqual(state.subtitleStyle(appWide: appWide).fontSize, 70, "工程：之前改的字号还在（从此刻用的那套改起）")

    try? change(["highlight": "#00E5FF"])?.apply(to: &state, appWide: appWide)
    checkEqual(state.subtitleHighlight?.scale, SubtitleWordHighlight.defaultScale, "高亮：打开时默认放大 1.1 倍")
    try? change(["highlight_scale": 1])?.apply(to: &state, appWide: appWide)
    checkEqual(state.subtitleHighlight, SubtitleWordHighlight(color: SubtitleColor(red: 0, green: 0xE5 / 255.0, blue: 1), scale: 1),
               "高亮：只给倍数时颜色照旧")
    let described = AISubtitleStyleChange.describe(state, appWide: appWide)
    checkEqual(described["own_style"], .bool(true), "回给 AI：这个工程用自己的样式")
    checkEqual(described["position"]?.stringValue, "top", "回给 AI：位置")
    checkEqual(described["highlight"]?.stringValue, "#00E5FF", "回给 AI：高亮颜色")
    try? change(["highlight": "none"])?.apply(to: &state, appWide: appWide)
    checkEqual(state.subtitleHighlight, nil, "高亮：none 关掉")

    try? change(["reset": true])?.apply(to: &state, appWide: appWide)
    checkEqual(state.projectSubtitleStyle, nil, "工程：reset 回到烧录页的样式")
    try? change(["reset": true, "color": "#FFFFFF", "bold": false])?.apply(to: &state, appWide: appWide)
    checkEqual(state.projectSubtitleStyle?.fontSize, appWide.fontSize, "工程：reset 之后再改，从烧录页那套改起")
    checkEqual(state.projectSubtitleStyle?.bold, false, "工程：reset 之后的改动照样生效")
    state.subtitleLayout = SubtitleLayout(marginLeft: 0, marginRight: 0, marginBottom: 200)
    checkEqual(AISubtitleStyleChange.describe(state, appWide: appWide)["position"]?.stringValue,
               "dragged in the preview (a custom spot)", "回给 AI：拖过框的说是自己摆的位置")
}

private func styleForBurnBatch() {
    let base = BurnInStyle.default
    let boxed = (try? change(["box": "#00000099"]))?.applied(to: base)
    checkEqual(boxed?.borderStyle, .box, "烧录一批：给了底条就是底条模式")
    checkEqual(boxed?.outlineWidth, 6, "烧录一批：底条的内边距默认 6")
    let backToOutline = boxed.flatMap { (try? change(["outline": "#000000"]))?.applied(to: $0) }
    checkEqual(backToOutline?.borderStyle, .outline, "烧录一批：给了描边就回到描边")
    checkEqual(backToOutline?.outlineWidth, 3, "烧录一批：从底条回到描边时粗细回到 3（不沿用内边距）")
    checkEqual((try? change(["outline": "none"]))?.applied(to: base).outlineWidth, 0, "烧录一批：outline none = 不描边")
    // 阴影（2026-09-29 验收：纪录片的卡写着「白字加浅阴影」，AI 却没有这个参数）。
    let shadowed = (try? change(["shadow": "#000000B3"]))?.applied(to: base)
    checkEqual(shadowed?.shadowColor, SubtitleColor(red: 0, green: 0, blue: 0, opacity: 0xB3 / 255.0), "阴影：颜色带透明度")
    checkEqual(shadowed?.shadowOffset, 3, "阴影：打开时偏移 3（烧录页「白字阴影」那套）")
    checkEqual(shadowed.flatMap { (try? change(["shadow": "none"]))?.applied(to: $0).shadowOffset }, 0, "阴影：none 关掉")
    checkEqual((try? change(["shadow": true]))?.shadow, .some(AISubtitleStyleChange.defaultShadow), "阴影：写成 true 也认（set_text 的 shadow 是开关）")
    checkEqual((try? change(["shadow": false]))?.shadow, .some(nil), "阴影：false = 不要阴影")
    let unboxed = boxed.flatMap { (try? change(["shadow": "#000000B3"]))?.applied(to: $0) }
    check(unboxed?.borderStyle == .outline && unboxed?.outlineWidth == 3 && unboxed?.shadowOffset == 3,
          "阴影：底条模式里给阴影就回到描边（底条没有阴影，预览和烧录都不画）")
    check((try? change(["shadow": "#000000B3"]))?.changesLook == true, "阴影：算改了样子（工程从此用自己的样式）")
    var state = TimelineState()
    try? change(["shadow": "#00000099"])?.apply(to: &state, appWide: base)
    checkEqual(AISubtitleStyleChange.describe(state, appWide: base)["shadow"]?.stringValue, "#00000099", "阴影：回给 AI 看得见")
    checkEqual(base, BurnInStyle.default, "烧录一批：烧录页那套不动（值拷贝）")
    check((try? change(["highlight": "#FFFF00"]))?.changesHighlight == true, "烧录一批：高亮看得出来（工具据此拒绝：字幕文件没有词的时间）")
}
