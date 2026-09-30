import Foundation

// 断句时看哪些词（SubtitleBreaks 的词表，2026-09-30 从那个文件搬出来，它顶到 400 行了）：
// 英文里适合当一条开头的、不许留在末尾的；中文里不许起头的助词、句末语气词、适合起头的连词、不许收尾的连词介词。
// 规则的出处见 docs/architecture/subtitle-generation-style.md。

enum SubtitleBreakWords {
    /// 英文里适合当一条开头的词：连词、关系词，以及不紧贴前面那个词的介词（Netflix：在连词、介词前面断）。
    /// 「of」「to」不算：「bottom / of the world」「going / to walk」反而拆散了一个意思。
    static let goodStarts: Set<String> = [
        "and", "but", "or", "so", "because", "that", "which", "who", "whom", "whose", "when", "where",
        "while", "if", "unless", "until", "since", "although", "though", "as", "than", "whether",
        "in", "on", "at", "for", "with", "from", "into", "onto", "about", "after", "before",
        "between", "through", "during", "without", "like"
    ]
    /// 英文里不许留在一条末尾的词：冠词、限定词、介词、连词（含从句连词：「…my box until / it's…」
    /// 的 until 该起头，不该收尾）、物主代词、助动词、主语代词。
    static let danglingEnds: Set<String> = [
        "all", "each", "every", "some", "any", "no", "such",
        "because", "when", "where", "while", "if", "unless", "until", "since", "although", "though",
        "whether", "than",
        "a", "an", "the", "to", "of", "in", "on", "at", "for", "with", "from", "into", "onto", "about",
        "by", "as", "and", "or", "but", "so", "that", "which", "who", "my", "your", "his", "her", "its",
        "our", "their", "this", "these", "those", "is", "are", "was", "were", "be", "been", "am", "will",
        "would", "can", "could", "should", "have", "has", "had", "do", "does", "did", "not", "very",
        "i", "you", "he", "she", "we", "they", "i'm", "you're", "we're", "they're", "it's", "there's"
    ]
    /// 中文里不许起头的字（助词、语气词）。
    static let particles: Set<Character> = ["的", "了", "吗", "呢", "吧", "啊", "着", "过", "们", "地", "得", "么", "呀", "嘛"]
    /// 中文的句末语气词：转写常常不给标点，它后面就是句号该在的地方。
    static let sentenceFinalParticles: Set<Character> = ["呢", "吗", "吧", "啊", "呀", "嘛"]
    /// 中文里适合当一条开头的词（连词、话题转换的词）。
    static let chineseGoodStarts = [
        "如果", "因为", "所以", "但是", "而且", "然后", "虽然", "可是", "不过", "并且", "或者", "于是",
        "同时", "无论", "只要", "只有", "即使", "就算", "最后", "首先", "其次", "接着", "另外", "其实",
        "现在", "然而", "因此"
    ]
    /// 中文里不许留在一条末尾的词（连词、介词：开了头、话没说完）。只认整词 —— 「现在」不算「在」。
    static let chineseDanglingEnds = [
        "如果", "因为", "所以", "但是", "而且", "然后", "虽然", "可是", "不过", "并且", "或者", "于是",
        "就是", "还是", "只是", "在", "把", "被", "和", "跟", "与", "对", "从", "向", "给", "让", "为", "将", "比",
        "我", "你", "他", "她", "它", "我们", "你们", "他们", "她们", "这", "那", "这个", "那个", "这些", "那些", "一个"
    ]
}
