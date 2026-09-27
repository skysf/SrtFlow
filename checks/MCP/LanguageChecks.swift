import Foundation

// 翻译前按字判断原文是什么语言（docs/bugfixes/2026-09-27-ai-translation-stale-source-language.md）。
// AI 把原文整轨改写成中文之后，工程里记的还是英文 —— 按记的去翻就是「英文→韩文」翻中文字幕。
// 翻译工具先按字判断、判不出来才退回记的，由 scripts/check-mcp.sh 里的扫描那一段钉着。

func runLanguageChecks() {
    let chinese = ["我们到南极了", "这里的企鹅一点也不怕人", "今天的风很大，船在冰面上慢慢地走"]
    let english = ["We finally made it to Antarctica", "The penguins are not afraid of people at all", "The wind is strong today"]
    let korean = ["우리는 마침내 남극에 도착했다", "펭귄들은 사람을 전혀 두려워하지 않는다"]
    checkEqual(AITextLanguage.dominant(in: chinese), "zh-Hans", "Chinese lines are read as zh-Hans")
    checkEqual(AITextLanguage.dominant(in: english), "en", "English lines are read as en")
    checkEqual(AITextLanguage.dominant(in: korean), "ko", "Korean lines are read as ko")
    check(AITextLanguage.dominant(in: []) == nil, "no lines: nothing to judge, fall back to what the project says")
    check(AITextLanguage.dominant(in: ["  ", ""]) == nil, "blank lines: nothing to judge")
}
