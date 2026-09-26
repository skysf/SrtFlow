import Foundation
import SrtFlowCore

// 生成 / 翻译出来的字幕去标点（SubtitlePunctuation）。规则与出处见
// docs/architecture/subtitle-generation-style.md「标点」一节。

func runSubtitlePunctuationChecks() {
    func stripped(_ text: String) -> String { SubtitlePunctuation.strip(text) }

    // 用户截图里的三句（图 3、4、5）。
    checkEqual(stripped("在世界的底部，有一个大陆"), "在世界的底部 有一个大陆", "标点：句中的中文逗号换成一个半角空格")
    checkEqual(stripped("只是从一个盒子移动到下一个盒子。"), "只是从一个盒子移动到下一个盒子", "标点：句尾的句号直接删")
    checkEqual(stripped("just moving from one box to the next."), "just moving from one box to the next",
               "标点：英文行也去（用户拍板两行一致）")
    checkEqual(stripped("you're born inside a box, a hospital, driven home"),
               "you're born inside a box a hospital driven home", "标点：英文逗号去掉、撇号不动、不留双空格")

    // 留着的：问号、叹号、引号、书名号、省略号、间隔号、列举中间的顿号。
    checkEqual(stripped("南极洲？"), "南极洲？", "标点：问号留着")
    checkEqual(stripped("Antarctica?"), "Antarctica?", "标点：英文问号留着")
    checkEqual(stripped("太冷了！真的。"), "太冷了！真的", "标点：叹号留着，后面的句号删")
    checkEqual(stripped("他说：“你好。”"), "他说 “你好”", "标点：冒号换空格；引号里句尾的句号删、引号留着")
    checkEqual(stripped("我读过《三体》，很好看。"), "我读过《三体》 很好看", "标点：书名号留着")
    checkEqual(stripped("我走路、跑步、骑自行车。"), "我走路、跑步、骑自行车", "标点：列举中间的顿号留着")
    checkEqual(stripped("家、学校、"), "家、学校", "标点：行尾的顿号删")
    checkEqual(stripped("Wait... what?"), "Wait… what?", "标点：半角省略号统一成「…」、留着")
    checkEqual(stripped("约翰·史密斯，你好"), "约翰·史密斯 你好", "标点：人名间隔号留着")

    // 数字、缩写、网址里的点 / 逗号 / 冒号不是停顿。
    checkEqual(stripped("minus 89.2 degrees Celsius, and today,"), "minus 89.2 degrees Celsius and today",
               "标点：小数点不动")
    checkEqual(stripped("It costs 1,000 dollars."), "It costs 1,000 dollars", "标点：千分位逗号不动")
    checkEqual(stripped("See you at 10:30."), "See you at 10:30", "标点：时间里的冒号不动")
    checkEqual(stripped("in the U.S. today."), "in the U.S. today", "标点：缩写 U.S. 的点不动")
    checkEqual(stripped("e.g., apples"), "e.g. apples", "标点：缩写后面的逗号照去")
    checkEqual(stripped("visit apple.com now."), "visit apple.com now", "标点：网址里的点不动")
    checkEqual(stripped("Mr. Smith"), "Mr Smith", "标点：单段缩写（Mr.）照英式写法去点")

    // 中文转写把逗号吐成带前导空格的一个词（「越来越多 ，把」）：不许留两个空格。
    checkEqual(stripped("越来越多 ，把硬盘都撑爆了 ，剪映"), "越来越多 把硬盘都撑爆了 剪映",
               "标点：转写出来的「 ，」只留一个空格")
    checkEqual(stripped("导出视频的大小呢 ？"), "导出视频的大小呢？", "标点：转写出来的「 ？」前面的空格去掉")
    // 引号、括号紧挨着的标点：不补空格。
    checkEqual(stripped("“你好，”他说"), "“你好”他说", "标点：右引号前面不补空格")
    checkEqual(stripped("（注意，）"), "（注意）", "标点：右括号前面不补空格")
    // 只有标点的行去空了就不留；多行逐行处理。
    checkEqual(stripped("。"), "", "标点：只有句号的字幕去成空")
    checkEqual(stripped("第一行，\n第二行。"), "第一行\n第二行", "标点：逐行去、换行留着")
    checkEqual(stripped("，开头的逗号"), "开头的逗号", "标点：行首的逗号直接删、不补空格")

    // 缩写判定（分段器也用它：缩写的点不是句号）。
    check(SubtitlePunctuation.isAcronym("U.S."), "缩写：U.S.")
    check(SubtitlePunctuation.isAcronym(" e.g.,"), "缩写：带前导空格和后缀逗号的 e.g.")
    check(SubtitlePunctuation.isAcronym("Ph.D."), "缩写：Ph.D.")
    check(!SubtitlePunctuation.isAcronym("Mr."), "缩写：Mr. 只有一段，不算")
    check(!SubtitlePunctuation.isAcronym("box."), "缩写：普通词加句号不算")
    check(!SubtitlePunctuation.isAcronym("89.2."), "缩写：数字不算")

    // 机器翻译落字那一刻去标点；已有的测试夹具里的「阿！」这类照原样。
    let source = SubtitleCue(start: 0, end: 2, text: "Hello, world.")
    let original = SubtitleDocumentModel(cues: [source])
    var companion = SubtitleCompanion()
    SubtitleRetranslation.apply([source.id: "你好，世界。"], snapshot: [source.id: source.text], scope: .all,
                                original: original, companion: &companion)
    checkEqual(companion.translation?.cues.map(\.text), ["你好 世界"], "标点：机器翻译落字时去标点")
    var onlyMarks = SubtitleCompanion()
    SubtitleRetranslation.apply([source.id: "。"], snapshot: [source.id: source.text], scope: .all,
                                original: original, companion: &onlyMarks)
    checkEqual(onlyMarks.translation?.cues.count ?? 0, 0, "标点：翻回来只有标点的不落空句")
    // 手改译文不走去标点：用户自己打的标点留着。
    var edited = companion
    if let id = edited.translation?.cues.first?.id {
        var doc = original
        SubtitleTrackEditing.setText(id: id, text: "你好，世界！", original: &doc, companion: &edited)
        checkEqual(edited.translation?.cues.first?.text, "你好，世界！", "标点：手改的译文一个标点都不动")
    }
}
