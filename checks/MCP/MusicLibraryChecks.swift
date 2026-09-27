import CoreGraphics
import Foundation
import SrtFlowMCPKit

// 音乐库写给 AI 看（AIMusicCredits）：CC0 不署名、同一句只出一次、按艺人和标题排；一首的样子里有 id、英文标签、
// 授权和署名句，默认值（没人声、没下载）不写。get_timeline 里音乐库的段写 library_id、不写缓存里的文件路径。
// 编法见 scripts/check-mcp.sh。

func runMusicLibraryChecks() {
    checkCreditLines()
    checkTrackDescription()
    checkLibraryClipInTimeline()
}

private func track(_ id: String, artist: String, title: String, code: String = "CC-BY-4.0") -> AudioLibraryItem {
    AudioLibraryItem(
        id: id, kind: .music, title: title, artist: artist, album: "", duration: 125.5, size: 1, url: URL(string: "https://example.com/\(id).m4a")!,
        cover: nil, loudness: -14.26, peakLimited: false, hasVocals: false, intensity: 3,
        tags: [AudioLibraryTag(zh: "平静", en: "calm", group: "mood")],
        license: AudioLibraryLicense(code: code, by: artist, src: nil, text: "\(title) by \(artist) (\(code))")
    )
}

private func checkCreditLines() {
    let lines = AIMusicCredits.lines([
        track("b", artist: "Zed", title: "Night"),
        track("a", artist: "Amy", title: "Morning"),
        track("c", artist: "Amy", title: "Free", code: "CC0-1.0"),
        track("b", artist: "Zed", title: "Night")
    ])
    checkEqual(lines, ["Morning by Amy (CC-BY-4.0)", "Night by Zed (CC-BY-4.0)"],
               "CC0 needs no credit, the same line appears once, sorted by artist then title")
    checkEqual(AIMusicCredits.lines([]), [], "no music, no credits")
}

private func checkTrackDescription() {
    let described = AIMusicCredits.describe(track("m1", artist: "Amy", title: "Morning"), downloaded: false)
    checkEqual(described["id"]?.stringValue, "m1", "the id add_clips takes")
    checkEqual(described["tags"]?.arrayValue?.compactMap(\.stringValue), ["calm"], "tags in English")
    checkEqual(described["loudness_lufs"]?.doubleValue, -14.3, "loudness rounded to 0.1 LUFS")
    checkEqual(described["credit"]?.stringValue, "Morning by Amy (CC-BY-4.0)", "the credit line as the manifest gives it")
    check(described["vocals"] == nil && described["downloaded"] == nil, "defaults are left out")
    var vocal = track("m2", artist: "Amy", title: "Song")
    vocal.hasVocals = true
    let downloaded = AIMusicCredits.describe(vocal, downloaded: true)
    check(downloaded["vocals"]?.boolValue == true && downloaded["downloaded"]?.boolValue == true, "vocals and downloaded are shown")
}

private func checkLibraryClipInTimeline() {
    var state = TimelineState()
    var music = audioClip(0, 30)
    music.remoteKey = "m1"
    state.audioTracks = [EditLane(clips: [music, audioClip(40, 5)])]
    let context = AITimelineSummary.Context(
        ids: AIShortIDs(state: state), workspace: nil, playhead: 0, selection: [], renderSize: CGSize(width: 1920, height: 1080)
    )
    let clips = AITimelineSummary.make(state, context)["tracks"]?.arrayValue?.last?["clips"]?.arrayValue ?? []
    checkEqual(clips.first?["library_id"]?.stringValue, "m1", "a library clip shows its library id")
    check(clips.first?["file"] == nil, "and not the path inside SrtFlow's cache")
    check(clips.last?["file"] != nil && clips.last?["library_id"] == nil, "an ordinary clip keeps its file")
}
