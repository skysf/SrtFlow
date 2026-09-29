import Foundation
import SrtFlowMCPKit

// 第四组：fal 回来的东西。
// 每个登记端点的样例输出（照它的输出定义写、并且先对着快照验一遍，免得样例自己写成定义里没有的形状）读出下载地址和后缀；
// 旁白模型报的词时间认三种写法（fal 没写元素的形状，读不出来就当没有）。

private func json(_ text: String) -> JSONValue {
    (try? JSONValue.decode(Data(text.utf8))) ?? .null
}

func runOutputChecks() {
    // ---- 每个登记端点的样例输出
    let samples: [(endpoint: String, kind: FalModel.Kind, output: String, ext: String, url: String)] = [
        ("bytedance/seedream/v5/flash/text-to-image", .image,
         #"{"images":[{"url":"https://v3b.fal.media/files/b/1/pic.png","content_type":"image/png","file_name":"pic.png","width":1536,"height":864}]}"#,
         "png", "https://v3b.fal.media/files/b/1/pic.png"),
        ("minimax/h3-max/text-to-video", .textToVideo,
         #"{"video":{"url":"https://v3b.fal.media/files/b/2/clip.mp4","content_type":"video/mp4","file_name":"clip.mp4","file_size":1234},"expanded_prompt":"a fox"}"#,
         "mp4", "https://v3b.fal.media/files/b/2/clip.mp4"),
        ("minimax/h3-max/image-to-video", .imageToVideo,
         #"{"video":{"url":"https://v3b.fal.media/files/b/3/anim"}}"#, "mp4", "https://v3b.fal.media/files/b/3/anim"),
        ("elevenlabs/tts/eleven-v4", .voice,
         #"{"audio":{"url":"https://v3b.fal.media/files/b/4/say.mp3","content_type":"audio/mpeg"},"timestamps":[{"word":"Hi","start":0.0,"end":0.3}]}"#,
         "mp3", "https://v3b.fal.media/files/b/4/say.mp3"),
        ("fal-ai/zonos2", .voiceClone,
         #"{"seed":5,"audio":{"url":"https://v3b.fal.media/files/b/5/clone","content_type":"audio/wav"}}"#, "wav", "https://v3b.fal.media/files/b/5/clone"),
        ("elevenlabs/music/v2.5", .music,
         #"{"audio":{"url":"https://v3b.fal.media/files/b/6/song","content_type":"audio/mpeg; charset=binary"}}"#, "mp3", "https://v3b.fal.media/files/b/6/song"),
        ("sonilo/v1.1/text-to-sound-effects", .soundEffect,
         #"{"audio":{"url":"https://v3b.fal.media/files/b/7/door.wav","content_type":"audio/wav"},"audios":[{"url":"https://v3b.fal.media/files/b/7/door.wav"}]}"#,
         "wav", "https://v3b.fal.media/files/b/7/door.wav")
    ]
    for sample in samples {
        let output = json(sample.output)
        checkValidOutput(sample.endpoint, output, "the sample output of \(sample.endpoint) follows its output schema")
        do {
            let media = try FalOutputs.media(from: output, kind: sample.kind)
            checkEqual(media.url.absoluteString, sample.url, "\(sample.endpoint): the download address")
            checkEqual(media.fileExtension, sample.ext, "\(sample.endpoint): the file extension")
        } catch {
            check(false, "\(sample.endpoint): could not read the media: \(error)")
        }
    }
    // 图片带宽高
    if let picture = try? FalOutputs.media(from: json(samples[0].output), kind: .image) {
        checkEqual(picture.width, 1536, "an image's width is read")
        checkEqual(picture.height, 864, "an image's height is read")
    }
    // 音乐 / 旁白自己报的时长
    let timed = try? FalOutputs.media(from: json(#"{"audio":{"url":"https://x.test/a.mp3","duration":12.5}}"#), kind: .voice)
    checkClose(timed?.duration, 12.5, "an audio duration is read when fal gives it")
    let topLevel = try? FalOutputs.media(from: json(#"{"audio":{"url":"https://x.test/a.wav"},"duration":31.2}"#), kind: .music)
    checkClose(topLevel?.duration, 31.2, "a duration next to the file is read too (MiniMax Music)")

    // ---- 找不到 / 不能下
    checkThrows("an answer without a file") { _ = try FalOutputs.media(from: json(#"{"description":"nope"}"#), kind: .image) }
    checkThrows("an empty images list") { _ = try FalOutputs.media(from: json(#"{"images":[]}"#), kind: .image) }
    checkThrows("a file that is not a web address") { _ = try FalOutputs.media(from: json(#"{"video":{"url":"file:///etc/passwd"}}"#), kind: .textToVideo) }
    checkThrows("a data: address (SrtFlow never asks for sync_mode)") { _ = try FalOutputs.media(from: json(#"{"images":[{"url":"data:image/png;base64,AAAA"}]}"#), kind: .image) }
    checkThrows("a file object without a url") { _ = try FalOutputs.media(from: json(#"{"video":{"content_type":"video/mp4"}}"#), kind: .textToVideo) }

    // ---- 后缀：文件名 > content-type > 地址 > 这一类的默认
    let url = URL(string: "https://x.test/files/blob")!
    checkEqual(FalOutputs.fileExtension(name: "a.MP4", contentType: "image/png", url: url, kind: .image), "mp4", "the file name wins")
    checkEqual(FalOutputs.fileExtension(name: nil, contentType: "audio/x-wav", url: url, kind: .music), "wav", "then the content type")
    checkEqual(FalOutputs.fileExtension(name: nil, contentType: nil, url: URL(string: "https://x.test/a/b.webp")!, kind: .image), "webp", "then the address")
    checkEqual(FalOutputs.fileExtension(name: "x.exe", contentType: nil, url: url, kind: .image), "png", "an extension outside the list is not trusted")
    checkEqual(FalOutputs.fileExtension(name: nil, contentType: nil, url: url, kind: .textToVideo), "mp4", "video defaults to mp4")
    checkEqual(FalOutputs.fileExtension(name: nil, contentType: nil, url: url, kind: .soundEffect), "mp3", "audio defaults to mp3")

    // ---- 词时间：三种写法
    let objects = FalOutputs.wordTimes(from: json(#"{"timestamps":[{"word":"Hello","start":0.1,"end":0.5},{"word":"world.","start":0.6,"end":1.0}]}"#))
    checkEqual(objects, [FalWordTime(text: "Hello", start: 0.1, end: 0.5), FalWordTime(text: "world.", start: 0.6, end: 1.0)], "objects with word / start / end")
    let named = FalOutputs.wordTimes(from: json(#"{"timestamps":[{"text":"你好","start_time":0.0,"end_time":0.4}]}"#))
    checkEqual(named, [FalWordTime(text: "你好", start: 0, end: 0.4)], "objects with text / start_time / end_time")
    let triples = FalOutputs.wordTimes(from: json(#"{"timestamps":[["a",0,0.2],["b",0.3,0.5]]}"#))
    checkEqual(triples.map(\.text), ["a", "b"], "triples [text, start, end]")
    let alignment = FalOutputs.wordTimes(from: json(
        #"{"timestamps":[{"characters":["H","i"," ","y","o"],"character_start_times_seconds":[0,0.1,0.2,0.3,0.4],"character_end_times_seconds":[0.1,0.2,0.3,0.4,0.5]}]}"#
    ))
    checkEqual(alignment, [FalWordTime(text: "Hi", start: 0, end: 0.2), FalWordTime(text: "yo", start: 0.3, end: 0.5)], "ElevenLabs' character alignment is grouped into words")
    let nested = FalOutputs.wordTimes(from: json(
        #"{"timestamps":{"alignment":{"characters":["o","k"],"character_start_times_seconds":[0,0.1],"character_end_times_seconds":[0.1,0.2]}}}"#
    ))
    checkEqual(nested.map(\.text), ["ok"], "alignment nested in an object")
    let perCharacter = FalOutputs.wordTimes(from: json(#"{"timestamps":[{"text":"o","start":0,"end":0.1},{"text":"k","start":0.1,"end":0.2},{"text":" ","start":0.2,"end":0.25},{"text":"y","start":0.25,"end":0.3}]}"#))
    checkEqual(perCharacter.map(\.text), ["ok", "y"], "one character per entry is grouped by spaces")

    let chinese = FalOutputs.wordTimes(from: json(#"{"timestamps":[{"characters":["你","好"],"character_start_times_seconds":[0,0.2],"character_end_times_seconds":[0.2,0.4]}]}"#))
    checkEqual(chinese.map(\.text), ["你", "好"], "Chinese without spaces: one character per word")
    let single = FalOutputs.wordTimes(from: json(#"{"timestamps":[{"characters":["H","e","l","l","o"],"character_start_times_seconds":[0,0.1,0.2,0.3,0.4],"character_end_times_seconds":[0.1,0.2,0.3,0.4,0.5]}]}"#))
    checkEqual(single.map(\.text), ["Hello"], "one Latin word reported by letter stays one word")
    let letters = FalOutputs.wordTimes(from: json(#"{"timestamps":[{"word":"I","start":0,"end":0.1},{"word":"a","start":0.2,"end":0.3}]}"#))
    checkEqual(letters.map(\.text), ["I", "a"], "single-letter words are not glued together")

    // ---- 不像样的词时间一律当没有
    check(FalOutputs.wordTimes(from: json(#"{"audio":{"url":"https://x.test/a.mp3"}}"#)).isEmpty, "no timestamps")
    check(FalOutputs.wordTimes(from: json(#"{"timestamps":null}"#)).isEmpty, "null timestamps")
    check(FalOutputs.wordTimes(from: json(#"{"timestamps":[]}"#)).isEmpty, "an empty list")
    check(FalOutputs.wordTimes(from: json(#"{"timestamps":[{"word":"a","start":1,"end":0.5}]}"#)).isEmpty, "a word that ends before it starts")
    check(FalOutputs.wordTimes(from: json(#"{"timestamps":[{"word":"a","start":1,"end":2},{"word":"b","start":0.5,"end":0.9}]}"#)).isEmpty, "words going backwards in time")
    check(FalOutputs.wordTimes(from: json(#"{"timestamps":[{"word":"a","start":-1,"end":2}]}"#)).isEmpty, "a negative start")
    check(FalOutputs.wordTimes(from: json(#"{"timestamps":[{"speaker":1}]}"#)).isEmpty, "entries in a shape SrtFlow does not know")
    check(FalOutputs.wordTimes(from: json(#"{"timestamps":"00:00:01"}"#)).isEmpty, "a string instead of a list")
    check(FalOutputs.wordTimes(from: json(#"{"timestamps":[{"characters":["a"],"character_start_times_seconds":[0,1],"character_end_times_seconds":[1]}]}"#)).isEmpty, "alignment arrays of different lengths")
}
