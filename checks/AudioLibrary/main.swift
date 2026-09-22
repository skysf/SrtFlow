import Foundation

// 音频库清单（manifest）的回归。两组：
//
// 一、**解析的宽容边界**。这份 JSON 来自 R2，不是本地资源 —— 它会先于 App
//    更新，也会后于 App 更新。所以「什么该忍、什么该拒」必须钉死：
//    不认识的字段忍（以后加字段不用动老 App）、缺的可选字段走默认、
//    **单条坏数据跳过而不是整份失败**（一首歌的 url 写错不该让整个库打不开），
//    但**版本号比自己新时整份拒绝** —— 那不是坏数据，是这份清单不是给我读的，
//    硬读出来的东西会以"能用"的样子出错，比直接说不认识更难查。
//
// 二、**双语搜索**。用户会搜「悲伤」也会搜「sad」，而 tag 是数据不是界面文案
//    （双语对照就在 JSON 里，不进 Localizable.strings）。多个词之间是**与**：
//    搜「dark piano」要的是既黑暗又有钢琴的，不是两者随便沾一个。
//
// 产品口径见 docs/plans/2026-09-22-audio-library.md 第四、十二节。
// 编译方式见 scripts/check-audio-library.sh。

var failures = 0
var checks = 0

func check(_ condition: Bool, _ message: String, line: Int = #line) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL [line \(line)] \(message)")
    }
}

func checkEqual<T: Equatable>(
    _ actual: T?, _ expected: T?, _ message: String, line: Int = #line
) {
    checks += 1
    if actual != expected {
        failures += 1
        print("FAIL [line \(line)] \(message)：得 \(String(describing: actual))，期望 \(String(describing: expected))")
    }
}

func json(_ s: String) -> Data { Data(s.utf8) }

/// 一条完整合法的素材，各用例在它基础上改。
let goodItem = """
{
  "id": "mus_1", "kind": "music", "title": "Distant Shore", "artist": "Someone",
  "album": "Tides", "duration": 184.2, "size": 4412160,
  "url": "https://downloads.skylu.ai/Audio/Music/mus_1.m4a",
  "cover": "https://downloads.skylu.ai/Audio/Music/covers/mus_1.jpg",
  "loudness": -16.04, "peak_limited": false, "has_vocals": false, "intensity": 2,
  "tags": [
    {"zh": "悲伤", "en": "sad", "group": "mood"},
    {"zh": "钢琴", "en": "piano", "group": "texture"}
  ],
  "license": {"code": "CC-BY-3.0", "by": "Someone", "src": "https://www.jamendo.com/track/1", "text": "Distant Shore by Someone"}
}
"""

func wrap(_ items: String, version: Int = 1) -> Data {
    json("""
    {"manifest_version": \(version), "kind": "music", "generated_at": "2026-09-22T00:00:00Z",
     "items": [\(items)]}
    """)
}

// MARK: - 一、解析的宽容边界

func parsing() {
    // ── 正常一条：每个字段都落到位
    guard let m = try? AudioLibraryManifest.parse(wrap(goodItem)) else {
        check(false, "合法清单应当解析成功"); return
    }
    checkEqual(m.version, 1, "版本号")
    checkEqual(m.items.count, 1, "条目数")
    let it = m.items[0]
    checkEqual(it.id, "mus_1", "id")
    checkEqual(it.title, "Distant Shore", "标题")
    checkEqual(it.duration, 184.2, "时长")
    checkEqual(it.intensity, 2, "强度")
    checkEqual(it.tags.count, 2, "标签数")
    checkEqual(it.license.code, "CC-BY-3.0", "授权码")
    checkEqual(it.url.absoluteString,
               "https://downloads.skylu.ai/Audio/Music/mus_1.m4a",
               "url 必须原样用 manifest 给的完整地址，不许拼路径")

    // ── 版本号比 App 新：整份拒绝，**不半解析**
    do {
        _ = try AudioLibraryManifest.parse(wrap(goodItem, version: 99))
        check(false, "更高版本的清单必须抛错，不能静默半解析")
    } catch let e as AudioLibraryManifest.ParseError {
        checkEqual(e, .unsupportedVersion(found: 99, supported: 1), "错误类型")
    } catch {
        check(false, "应当抛 ParseError.unsupportedVersion")
    }

    // ── 不认识的字段：忍。以后 manifest 加字段，老 App 照常能读
    let futureFields = goodItem.replacingOccurrences(
        of: "\"intensity\": 2",
        with: "\"intensity\": 2, \"bpm\": 72, \"stems\": [\"drums\"], \"whatever\": {\"a\": 1}")
    checkEqual((try? AudioLibraryManifest.parse(wrap(futureFields)))?.items.count, 1,
               "多出来的字段应当被忽略而不是让整条失败")

    // ── 缺可选字段：走默认值，不掉条
    let minimal = """
    {"id": "mus_2", "duration": 60, "url": "https://x/y.m4a",
     "license": {"code": "CC0"}}
    """
    guard let lean = try? AudioLibraryManifest.parse(wrap(minimal)), lean.items.count == 1 else {
        check(false, "只有必填字段的条目应当能解析"); return
    }
    let li = lean.items[0]
    checkEqual(li.title, "mus_2", "缺标题时退回 id，不能是空白")
    checkEqual(li.intensity, 3, "缺强度时取中间值 3")
    checkEqual(li.kind, .music, "缺 kind 时跟随清单的 kind")
    checkEqual(li.tags.count, 0, "缺 tags 时是空数组")
    checkEqual(li.peakLimited, false, "缺 peak_limited 时为假")
    check(!li.license.text.isEmpty, "没给署名句时要拼一句出来，署名页上不能是空的")

    // ── 单条坏数据：跳过那一条，其余照常。一首歌写错不该让整个库打不开
    let broken = [
        #"{"duration": 60, "url": "https://x/y.m4a", "license": {"code": "CC0"}}"#,          // 无 id
        #"{"id": "a", "url": "https://x/y.m4a", "license": {"code": "CC0"}}"#,               // 无时长
        #"{"id": "b", "duration": 60, "license": {"code": "CC0"}}"#,                         // 无 url
        #"{"id": "c", "duration": 60, "url": "https://x/y.m4a"}"#,                           // 无 license
        #"{"id": "d", "duration": 0, "url": "https://x/y.m4a", "license": {"code": "CC0"}}"#, // 时长为 0
    ].joined(separator: ",")
    let mixed = try? AudioLibraryManifest.parse(wrap(goodItem + "," + broken))
    checkEqual(mixed?.items.count, 1, "五条坏数据都该被跳过，好的那条要留下")

    // ── 只有一种语言的 tag：丢掉那个 tag（另一种语言下会变空白），但条目保留
    let halfTag = goodItem.replacingOccurrences(
        of: #"{"zh": "钢琴", "en": "piano", "group": "texture"}"#,
        with: #"{"zh": "钢琴", "group": "texture"}"#)
    let ht = try? AudioLibraryManifest.parse(wrap(halfTag))
    checkEqual(ht?.items.count, 1, "半个 tag 不该让整条掉")
    checkEqual(ht?.items.first?.tags.count, 1, "只有一种语言的 tag 要被丢掉")

    // ── 不是 JSON / 没有 items
    check((try? AudioLibraryManifest.parse(json("not json at all"))) == nil, "非 JSON 要抛错")
    check((try? AudioLibraryManifest.parse(json(#"{"manifest_version": 1}"#))) == nil,
          "缺 items 要抛错")

    // ── 强度越界要夹回 1–5，不能把越界值透给 UI
    let wild = goodItem.replacingOccurrences(of: "\"intensity\": 2", with: "\"intensity\": 99")
    checkEqual((try? AudioLibraryManifest.parse(wrap(wild)))?.items.first?.intensity, 5,
               "强度上界")
    let neg = goodItem.replacingOccurrences(of: "\"intensity\": 2", with: "\"intensity\": -3")
    checkEqual((try? AudioLibraryManifest.parse(wrap(neg)))?.items.first?.intensity, 1,
               "强度下界")

    // ── 实测响度必须原样透出来（不是目标值）：峰值顶住的那些就是偏轻的
    let quiet = goodItem
        .replacingOccurrences(of: "\"loudness\": -16.04", with: "\"loudness\": -21.27")
        .replacingOccurrences(of: "\"peak_limited\": false", with: "\"peak_limited\": true")
    let q = try? AudioLibraryManifest.parse(wrap(quiet))
    checkEqual(q?.items.first?.loudness, -21.27, "响度要存真值而不是 -16")
    checkEqual(q?.items.first?.peakLimited, true, "峰值顶住的标记要透出来")
}

// MARK: - 二、双语搜索

func searching() {
    let items = [
        item(id: "a", title: "Distant Shore", artist: "Alice",
             tags: [("悲伤", "sad", "mood"), ("钢琴", "piano", "texture")]),
        item(id: "b", title: "Iron Sky", artist: "Bob",
             tags: [("黑暗", "dark", "mood"), ("钢琴", "piano", "texture")]),
        // 曲名里**故意不含**任何 tag 词：否则「dark piano」会因为曲名命中 piano
        // 而把它也算进来，那验的就不是「与」而是巧合。
        item(id: "c", title: "Stone Lament", artist: "Carol",
             tags: [("黑暗", "dark", "mood"), ("弦乐", "strings", "texture")]),
    ]
    func ids(_ q: String) -> [String] {
        AudioLibraryManifest.filter(items, query: q).map(\.id)
    }

    checkEqual(ids(""), ["a", "b", "c"], "空查询返回全部")
    checkEqual(ids("   "), ["a", "b", "c"], "全空格也算空查询")

    // 中英各自命中
    checkEqual(ids("悲伤"), ["a"], "中文 tag 命中")
    checkEqual(ids("sad"), ["a"], "英文 tag 命中")
    checkEqual(ids("黑暗"), ["b", "c"], "中文 tag 命中多条")
    checkEqual(ids("dark"), ["b", "c"], "英文 tag 命中多条")

    // 大小写不敏感
    checkEqual(ids("DARK"), ["b", "c"], "大写也要命中")
    checkEqual(ids("Sad"), ["a"], "首字母大写也要命中")

    // 曲名和艺人也能搜
    checkEqual(ids("Shore"), ["a"], "曲名命中")
    checkEqual(ids("Bob"), ["b"], "艺人命中")
    checkEqual(ids("iron"), ["b"], "曲名大小写不敏感")

    // **多词是「与」不是「或」** —— 这一条是口径，不是实现细节
    checkEqual(ids("dark piano"), ["b"], "两个词都要满足")
    checkEqual(ids("黑暗 钢琴"), ["b"], "中文多词同理")
    checkEqual(ids("dark 钢琴"), ["b"], "中英混搜")
    checkEqual(ids("sad dark"), [], "互斥的两个词应当没有结果，而不是并起来")

    // 一个词命中曲名、另一个命中 tag
    checkEqual(ids("Lament 黑暗"), ["c"], "跨字段的与：一个命中曲名、一个命中 tag")

    checkEqual(ids("nonexistent"), [], "搜不到就是空")
}

func item(id: String, title: String, artist: String,
          tags: [(String, String, String)]) -> AudioLibraryItem {
    AudioLibraryItem(
        id: id, kind: .music, title: title, artist: artist, album: "",
        duration: 100, size: 1000, url: URL(string: "https://x/\(id).m4a")!,
        cover: nil, loudness: -16, peakLimited: false, hasVocals: false, intensity: 3,
        tags: tags.map { AudioLibraryTag(zh: $0.0, en: $0.1, group: $0.2) },
        license: AudioLibraryLicense(code: "CC-BY-3.0", by: artist, src: nil, text: "x")
    )
}

parsing()
searching()

print("\(checks) checks, \(failures) failures")
if failures > 0 { exit(1) }
print("All checks passed")
