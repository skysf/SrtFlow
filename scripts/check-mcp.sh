#!/usr/bin/env bash
# AI 接口（MCP）的自检：
#   1. 小程序 srtflow-mcp 说的 MCP 对不对 —— 真的起它，老一代（先 initialize）和新一代（2026-07-28，
#      每个请求自带 _meta 版本）两种客户端都喂一遍，旁边一个假 App 在临时 socket 上接工具调用；
#   2. App 里 AI 改时间线的纯值规则（放素材、推 V1、ripple 删、切、转场、改一段、短 id、get_timeline）；
#   3. 客户端配置文件的增删（Claude 的 JSON、Codex 的 TOML）、文字 / 颜色参数、字幕批量改；
#   4. 小程序那份选项词表和 App 里的类型逐项对账（小程序不链接 App 的代码，词表是抄的）；
#   5. 打包脚本把小程序装进了 Contents/Helpers，并且先签它、再签外层；
#   6. AI 的每个改动各是一步撤销：改工程的工具都包在 AIUndoGrouping.step 里（扫描），显式分组确实把两步分开、
#      而且之后按事件的普通登记不会抛异常（用真的 UndoManager）。
#   7. edit_clip 的画面（AIFrameFit）：铺满时源画面上那扇窗正好映到整幅画布（各种横竖比例、焦点贴边、超宽转竖屏），
#      完整显示 / 按位置大小摆、只改裁切不拉变形、约等于默认布局就存 nil；参数组合的冲突当场挡掉；
#      去黑边（AIBlackBars）：遮幅、柱边、暗场不算数、夜空的星星不是遮幅、遮幅里的字幕留着、几帧取最小，
#      真画一张图读回来第一行是画面最上面（上下弄反就裁错边）。
#   8. 铺满时对准谁（AISubjectFocus）：人脸优先、几张脸放得下对准中间放不下对准最大的、几帧取中位数、走动大了要说；
#      真画一张图（黑底左上角一块亮色）让 Vision 认，认出来的框必须在左上（Vision 是左下原点，换算反了窗就对错地方）。
#   9. look（「看」）：几帧排成格子、拼图的大小、JPEG、每帧的文字描述、结果里图跟在文字后面（MCP 的 image）；
#      大图穿过小程序 ↔ App 的通道原样回来（假 App 回一张几百 KB 的图）。
#  10. listen（「听」）：用生产的 ChunkBuilder 攒一份波形，量电平（只算有声音的部分）、峰值、静音段（窗和均方桶对齐，
#      交界不漏能量）、响度曲线、片段在时间线上听到的（变速换时间、段音量和轨道推子乘进去）。
#  11. read_document（读文稿）：现造 GBK 的 txt、RTF、docx、带字的 PDF 读回来对文字，Pages 要说清楚读不了，分段读的边界。
#  12. 用户文本文件的编码识别（SrtFlowCore 的 TextDecoding）：GBK 字幕单双字节都读对、UTF-16 带不带 BOM 都认、UTF-8 的 BOM 不留下。
#  13. manage_files（整理文件）：只在点名的文件夹里动、不覆盖、改名保留后缀、不许挪进自己里面；临时目录里真做一遍（含进废纸篓）。
#  14. open_folder from_finder：选中的东西登记哪个文件夹、只列哪些；Info.plist 有控制访达的用途说明（扫描）。
#  15. edit_clip 的其余设置（AIClipDetails）：旋转 / 不透明度、入场出场成对、音量曲线换源时间、有曲线时 volume_db 平移整条、
#      声音场景的旋钮名、标记；小程序抄的动画 / 场景 / 标记颜色词表和 App 的类型对账。
#  16. set_track（推子、藏轨、总推子）和 set_keyframes（时间换源时间、大小按默认布局、空列表去掉那一行）。
#  17. set_shape：新加要种类、默认大小、夹紧、正方形高等于宽、只有线能转。
#  18. duplicate_items：走 ⌘C / ⌘V 的纯函数，落点、往上抬、链接伙伴、新身份。
#  19. 剪辑风格（recipes / save_recipe）：配方卡的格式、合并与查找、存一套 / 删一套、工具的结果；五张内置卡都在，
#      卡里提到的工具名、参数名、选项值都存在；卡里的字号写明画幅，9:16 的上限用 set_text 的排版和 SubtitleLineFit
#      真排得下（2026-09-29，docs/bugfixes/2026-09-29-recipe-sizes-too-big-on-vertical.md）。
#  20. set_text 补的零件（字距、动画时长和强度、强调、数字滚动）和 set_shape 的实心。
#  21. add_voiceover：挑声音、标记 → 带时间的词、每一句放在哪、配音的字幕（不覆盖已有的、语言对不上不加）；
#      配音的音量（峰值超过满幅的一句真写成 .m4a 读回来不削波、说话部分同一个响度），两种声音都只经一处写文件（扫描）。
#      转写 / 生成字幕认不出语言时，AI 拿到「带上 language 再调」而不是面板那句（纯值 + 扫描）。
#  22. SrtFlow 自己的声音（Kokoro）：装了就用、角色对应的音色、放得下整句读 / 读不下切在离正中最近处、太短的垫一句（炸没炸、切口不越过垫的那句）、
#      拼接与裁尾巴、R2 清单的校验、按字 / 词切 token。
#  25. 盖一块（模糊 / 马赛克）的 AI 这一侧：set_shape 认 blur / mosaic（默认大小、strength 夹紧、不画东西所以没有颜色 / 线宽 / 实心、写回给 AI 的样子），
#      工具目录的种类词表和 ShapeKind 对账；look text_scan 对时间线上的一段把源画面的框换成画布的框（裁切 / 翻转 / 摆放 / 旋转）、给出 set_shape 能抄的参数。
#  24. 扫画面里的字（look text_scan）：字幕带、固定的字、满屏的字各认得出来；铺满时没人、字多就对准字，focus=text，字比窗宽说多少。
#  25. 生成类工具的提供方（方案第 36 条）：generate_media 只在配了 fal 时列出来（真起小程序：没配 / 配了各列什么、总说明配了才提 fal、
#      握手声明清单会变、新一代清单缓存一分钟；用户中途添加 / 删掉 Key 时老一代客户端收 list_changed、新一代不收）、那个小文件读得宽且不带机密、
#      说明和参数和词表 / App 的类型对账、全清单说明总长 ≤ 80,000 字符（2026-10-02 从 72,000 抬上来）；add_voiceover 的 fal 那一档：挑音色的优先级、角色表对账、
#      fal 报的词时间换成字幕认的词、克隆参考音频的 WAV（真去调 fal 在 scripts/check-fal.sh）。
#  23. 字幕长什么样（edit_subtitles / burn_subtitles 的 style）：参数全验过、只改工程自己的样式、给了位置收掉拖框的布局、
#      只给字号把倍率归一、逐词高亮的开关和倍数、烧录一批时描边 / 底条互换、位置词表对账。
#  27. upscale_clip（2026-10-02）：词表（档位 / 目标 / 范围）和 App 的类型对账、定义（参数、必填、枚举、只在配了 fal 时列、上网）、
#      说明里每个档位都点了名且「about N min」和典型时长一致、总说明的 fal 那一行带着它（UpscaleToolChecks）；
#      做完换源的那一下包在 AIUndoGrouping.step 里（异步落账，扫描）。
#  28. record_screen（2026-10-03）：参数怎么读、窗口 / 屏幕 / 麦克风怎么挑、区域的比例换成点、词表和 App 的类型对账、工具的定义
#      （ScreenRecordingToolChecks）；接线（AI 起的录制不开系统选择窗口、不覆盖、入轨包 step、录制中不摆窗口……）在
#      checks/screen-recording-ai-wiring.sh。
#  26. 给 AI 的文字按客户端怎么读来守：总说明和每个工具说明都在 Claude Code 的 2,048 字以内（它多了就静默截掉）、
#      总说明前 512 字自成一体（Codex）、目录里有清单的每个工具名、全部只用英文
#      （2026-09-30，docs/bugfixes/2026-09-30-mcp-text-truncated-at-2048.md）。
#
# 用法：
#   scripts/check-mcp.sh
#
# 与 check-timeline-clipboard.sh 同一套编法：被测代码在 SrtFlow app target 里，SwiftPM 不允许两个
# target 共用源文件，所以挑纯值文件单独编成自检二进制。长期约束见 docs/architecture/ai-control-mcp.md。
set -euo pipefail
cd "$(dirname "$0")/.."

# Rosetta 终端下必须显式指定 arm64，否则会去编 x86_64（见 docs/build/）。
ARCH_FLAG="--arch arm64"
TRIPLE="arm64-apple-macosx15.0"

echo "==> 打包脚本：小程序进 Helpers、先签它再签外层"
# 签名只经 scripts/signing/sign-app.sh 一处（docs/architecture/code-signing-and-permissions.md）：
# build-app.sh 要先把小程序拷进去再调它，它里面要先签小程序再签外层。
BUILD_SCRIPT="scripts/build-app.sh"
SIGN_SCRIPT="scripts/signing/sign-app.sh"
COPY_LINE="$(grep -n 'cp "$BUILD_DIR/srtflow-mcp" "$APP/Contents/Helpers/srtflow-mcp"' "${BUILD_SCRIPT}" | cut -d: -f1 || true)"
CALL_SIGN="$(grep -n '^scripts/signing/sign-app.sh "$APP"$' "${BUILD_SCRIPT}" | cut -d: -f1 || true)"
SIGN_HELPER="$(grep -n 'codesign --force "$@" --timestamp=none "${APP}/Contents/Helpers/srtflow-mcp"' "${SIGN_SCRIPT}" | cut -d: -f1 || true)"
SIGN_APP="$(grep -n 'codesign --force "$@" --timestamp=none "${APP}"$' "${SIGN_SCRIPT}" | cut -d: -f1 || true)"
if [ -z "${COPY_LINE}" ] || [ -z "${CALL_SIGN}" ] || [ -z "${SIGN_HELPER}" ] || [ -z "${SIGN_APP}" ]; then
  echo "✗ ${BUILD_SCRIPT} 没把 srtflow-mcp 拷进 Contents/Helpers，或 ${SIGN_SCRIPT} 没签它：AI 客户端配置里写的那个路径会不存在" >&2
  exit 1
fi
if [ "${COPY_LINE}" -gt "${CALL_SIGN}" ]; then
  echo "✗ ${BUILD_SCRIPT} 先签名再拷 srtflow-mcp：拷进去的小程序没签名，外层签名也立即失效" >&2
  exit 1
fi
if [ "${SIGN_HELPER}" -gt "${SIGN_APP}" ]; then
  echo "✗ ${SIGN_SCRIPT} 先签了外层再签 srtflow-mcp：嵌套的可执行文件必须先签，否则外层签名立即失效" >&2
  exit 1
fi
echo "   ✓ ${BUILD_SCRIPT} 第 ${COPY_LINE} 行拷进去、第 ${CALL_SIGN} 行才签；${SIGN_SCRIPT} 第 ${SIGN_HELPER} 行签小程序、第 ${SIGN_APP} 行才签外层"

echo "==> 路由：改工程的工具各是一步撤销"
# 不显式分组的话 AI 的每一步都堆进同一组，⌘Z 一按全部退光；手动关自动开的那一组又会让下一次登记
# 抛异常、App 闪退（docs/bugfixes/2026-09-27-ai-edits-share-one-undo-group.md）。
ROUTER="Sources/SrtFlow/AIToolRouter.swift"
for tool in setKeyframes setTrack splitClip deleteItems duplicateItems setTransition setText setShape setFilter setCanvas; do
  if [ "$(grep -cE "case \\.${tool}: return try AIUndoGrouping\\.step\\(undo\\)" "${ROUTER}" || true)" -ne 1 ]; then
    echo "✗ ${ROUTER} 里 ${tool} 没包在 AIUndoGrouping.step 里：它的改动会和别的步并成一步撤销" >&2
    exit 1
  fi
done
# edit_clip 先 await 看画面（去黑边、对准主体），再把同步的提交包起来：包的那一段不许有 await。
if [ "$(grep -cE 'return try AIUndoGrouping\.step\(undo\) \{ try AIClipTools\.apply\(plan, project\) \}' "${ROUTER}" || true)" -ne 1 ]; then
  echo "✗ ${ROUTER} 里 edit_clip 的提交没包在 AIUndoGrouping.step 里" >&2
  exit 1
fi
# edit_subtitles 给了字体要先等字体表（await），同样只把同步的提交包起来。
if [ "$(grep -cE 'return try AIUndoGrouping\.step\(undo\) \{ try AISubtitleTools\.edit\(args, style: style, project\) \}' "${ROUTER}" || true)" -ne 1 ]; then
  echo "✗ ${ROUTER} 里 edit_subtitles 的提交没包在 AIUndoGrouping.step 里" >&2
  exit 1
fi
for tool in AISpeechCutTool AIBeatCutTool AIVoiceoverTool; do
  if [ "$(grep -cE "return try AIUndoGrouping\\.step\\(undo\\) \\{ try ${tool}\\.apply\\(plan, project\\) \\}" "${ROUTER}" || true)" -ne 1 ]; then
    echo "✗ ${ROUTER} 里 ${tool} 的提交没包在 AIUndoGrouping.step 里" >&2
    exit 1
  fi
done
if [ "$(grep -cE 'AIUndoGrouping\.step\(project\.effectiveUndoManager\)' Sources/SrtFlow/AITimelineTools.swift || true)" -ne 1 ]; then
  echo "✗ add_clips 那一次 perform 没包在 AIUndoGrouping.step 里" >&2
  exit 1
fi
# freeze_frame 抽帧转码要 await：把「提交那一下」包进 AIUndoGrouping.step 交给定格去做。
if [ "$(grep -c 'AIUndoGrouping.step(undo, body)' Sources/SrtFlow/AIClipTools.swift || true)" -ne 1 ] \
   || [ "$(grep -c 'commit {' Sources/SrtFlow/VideoEditFreezeFrame.swift || true)" -ne 1 ]; then
  echo "✗ freeze_frame 的提交没包进 AIUndoGrouping.step（或定格没把 perform 交给 commit）" >&2
  exit 1
fi
MANUAL="$(grep -lE 'endUndoGrouping\(\)' Sources/SrtFlow/AI*.swift | grep -v 'AIUndoGrouping.swift' || true)"
if [ -n "${MANUAL}" ]; then
  echo "✗ 这些文件自己在关撤销组：${MANUAL}（手动关掉按事件自动开的那一组，下一次登记就抛异常、App 闪退）" >&2
  exit 1
fi
# 一处登记落在 step 外面就够把后面全并成一步：App 在后台收不到事件，按事件自动开的那一组关不上，之后每个 step
# 看见「开着一组」都嵌进去（2026-09-27 冒烟：add_clips 先挂字幕再进 step，撤一步整条时间线空了，
# docs/bugfixes/2026-09-27-ai-undo-swallowed-by-subtitle-attach.md）。add_clips 挂字幕必须在放素材的那个 step 里：
ADD_STEP="$(awk '/try AIUndoGrouping\.step\(project\.effectiveUndoManager\) \{/,/^        \}$/' Sources/SrtFlow/AITimelineTools.swift)"
if [ "$(grep -c 'project.attachSubtitle(' <<<"${ADD_STEP}" || true)" -ne 1 ] \
   || [ "$(grep -c 'project.attachSubtitle(' Sources/SrtFlow/AITimelineTools.swift || true)" -ne 1 ]; then
  echo "✗ add_clips 挂字幕不在放素材的那个 AIUndoGrouping.step 里：在后台的 App 里之后 AI 的每一步都会并进同一组" >&2
  exit 1
fi
# 不是用户事件引起的异步落账（AI 起的生成字幕 / 翻译结束时、静帧转换失败删占位块）也各包一层：落账那一行的上一行是 step。
for pair in "Sources/SrtFlow/SubtitleGen/TranscriptionTask.swift|project.replaceSubtitleForGeneration(" \
            "Sources/SrtFlow/SubtitleGen/SubtitleTranslationService.swift|project.applyTranslations(" \
            "Sources/SrtFlow/AIUpscaleTool.swift|project.applyUpscale("; do
  file="${pair%%|*}"
  call="${pair#*|}"
  if [ "$(grep -cF "${call}" "${file}" || true)" -ne 1 ] \
     || ! grep -q 'AIUndoGrouping.step(project.effectiveUndoManager) {' <<<"$(grep -B1 -F "${call}" "${file}" | head -1)"; then
    echo "✗ ${file} 的异步落账（${call}）没包在 AIUndoGrouping.step 里：AI 起的任务一结束，之后的改动撤一步全退" >&2
    exit 1
  fi
done
if grep -nE '^ +perform\(rebuildsPreview: false\) \{ \$0\.remove\(clipID\) \}' Sources/SrtFlow/VideoEditProject.swift; then
  echo "✗ 静帧转换失败删占位块的 perform 没包在 AIUndoGrouping.step 里（异步落账）" >&2
  exit 1
fi
echo "   ✓ 10 个同步的改动工具 + edit_clip / edit_subtitles / cut_speech / cut_to_beat / add_voiceover / freeze_frame 的提交 + add_clips（连同挂字幕）都各是一步；生成字幕、翻译写回、"
echo "     删占位块这些异步落账也各是一步；没人手动关撤销组"

echo "==> 看得见：窗口只在一轮开始时摆到前面"
# 每一步都 orderFrontRegardless 的话，用户在别的 App 里干活时 SrtFlow 一步一跳、盖住他的窗口
#（docs/plans/2026-09-27-mcp.md 第 32 条）。
PRESENTER="Sources/SrtFlow/AIEditorPresenter.swift"
if [ "$(grep -c 'let startsNewRound = AISession.shared.phase != .working' "${ROUTER}" || true)" -ne 1 ] \
   || [ "$(grep -c 'prepareEditor(project: project, bringForward: startsNewRound && visible && !recordingScreen)' "${ROUTER}" || true)" -ne 1 ]; then
  echo "✗ ${ROUTER} 没按「这一轮是不是刚开始」决定要不要把窗口摆到前面" >&2
  exit 1
fi
RAISE_BLOCK="$(awk '/if bringForward \{/,/^            \}/' "${PRESENTER}")"
if [ "$(grep -c 'orderFrontRegardless' "${PRESENTER}" || true)" -ne 2 ] \
   || [ "$(grep -c 'window.orderFrontRegardless()' <<<"${RAISE_BLOCK}" || true)" -ne 1 ]; then
  echo "✗ ${PRESENTER} 在 if bringForward 外面也把窗口摆到前面（一轮中途又会一步一跳）" >&2
  exit 1
fi
# 后台模式（方案第 7 条）：一次都不摆窗口、不跟着选中 / 挪播放头（seek 除外，它就是要给用户看那一刻）。
if [ "$(grep -c 'guard always || AISession.shared.viewMode == .visible else { return }' "${PRESENTER}" || true)" -ne 1 ]; then
  echo "✗ ${PRESENTER} 的 reveal 在后台模式下照样选中、挪播放头" >&2
  exit 1
fi
echo "   ✓ 路由按 AISession 判断一轮的第一步；摆窗口只在 if bringForward 里；后台模式不摆窗口、不跟着选中"

echo "==> 访达选中：Info.plist 里有控制访达的用途说明，每种界面语言都有"
# 没有 NSAppleEventsUsageDescription，macOS 不弹「想要控制访达」、直接拒绝，from_finder 永远拿不到东西（方案第 22 条）。
# InfoPlist.strings 按 Resources/*.lproj/ 现场找（加语言不用改这里）；一张都没找到就是目录搬了，当场红。
INFOPLIST_TABLES=(Sources/SrtFlow/Resources/*.lproj/InfoPlist.strings)
if [ "${#INFOPLIST_TABLES[@]}" -lt 2 ] || [ ! -f "${INFOPLIST_TABLES[0]}" ]; then
  echo "✗ Sources/SrtFlow/Resources/*.lproj/InfoPlist.strings 找到的不到两张：${INFOPLIST_TABLES[*]}" >&2
  exit 1
fi
for file in packaging/Info.plist "${INFOPLIST_TABLES[@]}"; do
  if [ "$(grep -c 'NSAppleEventsUsageDescription' "${file}" || true)" -ne 1 ]; then
    echo "✗ ${file} 里没有（或不止一条）NSAppleEventsUsageDescription：open_folder from_finder 问不了访达" >&2
    exit 1
  fi
done
echo "   ✓ Info.plist 和 ${#INFOPLIST_TABLES[@]} 张 InfoPlist.strings 都有控制访达的用途说明"

echo "==> 用户文本文件的编码只走 TextDecoding"
# .utf16 几乎什么都解得出来，排在 GBK 前面 GBK 就永远轮不到（docs/bugfixes/2026-09-27-gbk-subtitles-read-as-utf16.md）。
# 规则只许在 SrtFlowCore 的 TextDecoding 一处（docs/architecture/text-file-encoding.md）。
STRAY_UTF16="$(grep -rn 'encoding: \.utf16)' Sources | grep -v 'Sources/SrtFlowCore/TextDecoding.swift' || true)"
if [ -n "${STRAY_UTF16}" ]; then
  echo "✗ 这些地方自己在按 UTF-16 解码用户文件（改用 TextDecoding.decode）：" >&2
  echo "${STRAY_UTF16}" >&2
  exit 1
fi
echo "   ✓ 只有 TextDecoding 按 UTF-16 解码"

echo "==> 翻译：原文语言先按字判断，判不出来才用工程里记的"
# 反过来的话，AI 把原文改写成中文之后，系统照旧按「英文→韩文」去翻
#（docs/bugfixes/2026-09-27-ai-translation-stale-source-language.md）。
SUBTITLE_TOOLS="Sources/SrtFlow/AISubtitleTools.swift"
SOURCE_BODY="$(awk '/private static func translationSource\(/,/^    \}/' "${SUBTITLE_TOOLS}")"
DETECT_AT="$(grep -n 'AITextLanguage\.dominant' <<<"${SOURCE_BODY}" | head -1 | cut -d: -f1 || true)"
STORED_AT="$(grep -n 'subtitleCompanion?\.sourceLanguage' <<<"${SOURCE_BODY}" | head -1 | cut -d: -f1 || true)"
if [ -z "${DETECT_AT}" ] || [ -z "${STORED_AT}" ] || [ "${DETECT_AT}" -gt "${STORED_AT}" ]; then
  echo "✗ ${SUBTITLE_TOOLS} 的 translationSource 没有先按字判断原文语言（判断在第 ${DETECT_AT:-?} 行、旧记录在第 ${STORED_AT:-?} 行）" >&2
  exit 1
fi
if [ "$(grep -c 'let source = try translationSource(args, project)' "${SUBTITLE_TOOLS}" || true)" -ne 1 ]; then
  echo "✗ translate_subtitles 没走 translationSource：原文语言又会信旧记录" >&2
  exit 1
fi
echo "   ✓ 先判断（第 ${DETECT_AT} 行）、再退回旧记录（第 ${STORED_AT} 行）"

echo "==> 新东西默认放哪：点名的文件夹 → 工程的家 → 下载，没有「影片」；AI 改了没存过的工程马上存"
# 2026-09-27 用户拍板（docs/plans/2026-09-27-mcp.md 第 29、30 条）。规则只有 DefaultFolder 一份，
# 手动的打开 / 存储为面板、导出面板第一次用的位置、AI 的输出都从 AIWorkspace.startFolder 拿。
MOVIES="$(grep -rln 'moviesDirectory' Sources/SrtFlow || true)"
if [ -n "${MOVIES}" ]; then
  echo "✗ 这些文件又把默认位置指向「影片」：${MOVIES}（用户：不要到 Movies，没给文件夹就放下载）" >&2
  exit 1
fi
for wiring in "Sources/SrtFlow/VideoEditProjectDocument.swift:2" "Sources/SrtFlow/VideoEditExportSheet.swift:1" \
              "Sources/SrtFlow/AIWorkspace.swift:1"; do
  file="${wiring%%:*}"
  want="${wiring##*:}"
  if [ "$(grep -c 'startFolder(project:' "${file}" || true)" -lt "${want}" ]; then
    echo "✗ ${file} 的默认位置没走 AIWorkspace.startFolder（应有 ${want} 处）" >&2
    exit 1
  fi
done
if [ "$(grep -c 'AIProjectTools.saveIfNeverSaved(project, after: result)' "${ROUTER}" || true)" -ne 1 ]; then
  echo "✗ ${ROUTER} 改完工程没调 saveIfNeverSaved：AI 在没存过的工程上干的活，App 一崩就全丢" >&2
  exit 1
fi
echo "   ✓ 没有「影片」；三处默认位置走同一个起点；改工程的调用之后都会给没存过的工程存盘"

echo "==> 压缩 / 烧录：AI 的条目自带设置和输出位置，不替用户开跑"
# AI 给的参数只用于它排的那几条（不改页面上记住的设置），页面上改设置 / 输出文件夹不碰 AI 的条目；
# 队列停着、里面有用户自己排了没开始的就不排（start() 会把等着的一起跑掉）。docs/architecture/ai-control-mcp.md 第四节第 24 条。
QUEUE_FILE="Sources/SrtFlow/EncodeQueue.swift"
ENCODE_TOOLS="Sources/SrtFlow/AIEncodeTools.swift"
if [ "$(grep -c 'settings: item.ownSettings ?? settings' "${QUEUE_FILE}" || true)" -ne 1 ]; then
  echo "✗ ${QUEUE_FILE} 跑一条时没先用它自带的设置（item.ownSettings ?? settings）：AI 给的画质 / 分辨率会被页面上的盖掉" >&2
  exit 1
fi
if ! grep -q "status == .waiting && items\[index\].ownSettings == nil" "${QUEUE_FILE}"; then
  echo "✗ ${QUEUE_FILE} 的 refreshOutputPaths 会改 AI 条目的输出位置（结果里告诉 AI 的路径就不对了）" >&2
  exit 1
fi
if ! grep -q 'status == .waiting && \$0.ownSettings == nil' "${ENCODE_TOOLS}"; then
  echo "✗ ${ENCODE_TOOLS} 不再检查用户自己排着没开始的条目：AI 一 start 就替用户开跑了" >&2
  exit 1
fi
if grep -nE 'queue\.(settings|burnInStyle|outputDirectory|attachSoftSubtitleTrack) = ' "${ENCODE_TOOLS}"; then
  echo "✗ ${ENCODE_TOOLS} 改了页面上记住的设置：AI 的参数只许用于它自己那几条" >&2
  exit 1
fi
echo "   ✓ 自带设置先用、输出位置不被重算、有用户没开始的条目就不排、不改页面上的设置"

echo "==> 什么时候问：只有删文件，外加点名文件夹以外的文件问一次、记住那个文件夹"
# 2026-09-28 用户拍板（docs/plans/2026-09-27-mcp.md 第 34 条）：删进废纸篓先问；读点名文件夹以外的文件问一次，同意了就记住
# 那个文件夹（AIReadGrants），以后不问；从不覆盖（撞名加编号）、开着的工程没存过就先存下来再换，这两样都不问。
ASKERS="$(grep -rl 'AIConfirmations.shared.ask(' Sources/SrtFlow | sort | xargs -n1 basename | tr '\n' ' ')"
if [ "${ASKERS}" != "AIFileTools.swift AIWorkspace.swift " ]; then
  echo "✗ 会回 needs_confirmation 的地方变了：${ASKERS}（只许删文件的 AIFileTools、读别处文件的 AIWorkspace）" >&2
  exit 1
fi
if [ "$(grep -c 'AIReadGrants.shared.remember(' Sources/SrtFlow/AIWorkspace.swift || true)" -ne 1 ]; then
  echo "✗ AIWorkspace.confirmReading 点过头之后没记住那个文件夹：同一个文件夹里的文件会一次次地问" >&2
  exit 1
fi
for wiring in "Sources/SrtFlow/AIExportTools.swift:1" "Sources/SrtFlow/AIProjectTools.swift:3"; do
  file="${wiring%%:*}"
  want="${wiring##*:}"
  if [ "$(grep -c 'ExportFileName.unoccupied' "${file}" || true)" -lt "${want}" ]; then
    echo "✗ ${file} 撞名没走 ExportFileName.unoccupied（应有 ${want} 处）：AI 会覆盖文件、或者又回头问" >&2
    exit 1
  fi
done
echo "   ✓ 只有删文件和读别处的文件会问；读过的文件夹记住；导出、新建、另存撞名都加编号"

echo "==> 配音只经一处写文件（先过一道音量）"
# Kokoro 的 am_fenrir 峰值会超过满幅，没过音量就写进文件，一声声爆音（docs/bugfixes/2026-09-28-kokoro-voiceover-clipping.md）。
# 两种声音都只许经 AIAudioFileWriter.writeVoiceover 落盘、词的时间按它返回的那份算；写的那一步在自检二进制里真写真读。
for engine in Sources/SrtFlow/KokoroVoiceSpeech.swift Sources/SrtFlow/AISpeechSynthesis.swift Sources/SrtFlow/AIFalVoice.swift; do
  if [ "$(grep -c 'let samples = try AIAudioFileWriter.writeVoiceover(' "${engine}" || true)" -ne 1 ] \
     || [ "$(grep -c 'AVAudioFile(forWriting' "${engine}" || true)" -ne 0 ]; then
    echo "✗ ${engine} 没经 AIAudioFileWriter.writeVoiceover 写配音（或自己开了文件写）：没过音量的声音会削波" >&2
    exit 1
  fi
done
echo "   ✓ Kokoro、macOS 和 fal 的声音都经 writeVoiceover 写文件"

echo "==> 认不出语言时，AI 拿到的是它能照做的话"
# 自动检测没认出语言，界面那句「去面板里选」AI 做不到（docs/bugfixes/2026-09-29-ai-told-to-pick-language-in-panel.md）。
# 检测处抛 LanguageUndetectedError，transcribe、generate_subtitles 的任务失败都经 AIHarvestFailure 换成「带上 language 再调」。
if [ "$(grep -c 'throw LanguageUndetectedError()' Sources/SrtFlow/SubtitleGen/TranscriptHarvester.swift || true)" -ne 1 ] \
   || [ "$(grep -c 'AIHarvestFailure.message(' Sources/SrtFlow/AITranscribeTool.swift || true)" -ne 1 ] \
   || [ "$(grep -c 'AIHarvestFailure.message(' Sources/SrtFlow/AISubtitleTools.swift || true)" -ne 1 ]; then
  echo "✗ 认不出语言没抛成 LanguageUndetectedError，或 transcribe / generate_subtitles 的失败没经 AIHarvestFailure：AI 会被叫去面板里选" >&2
  exit 1
fi
echo "   ✓ 检测处抛 LanguageUndetectedError，两个任务的失败都经 AIHarvestFailure"

echo "==> 关掉主窗口不退出；小程序把 App 拉起来的那次，结果里告诉 AI"
# 2026-10-02 南极工程：SwiftUI 单 Window 场景关窗就退出，AI 下一次调用拉起来的是空的 Untitled、打开的文件夹也没了，
# 它只看到「文件不存在」（docs/bugfixes/2026-10-03-closing-window-quits-app.md）。
if [ "$(grep -c 'func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }' Sources/SrtFlow/SrtFlowApp.swift || true)" -ne 1 ]; then
  echo "✗ 关掉主窗口会退出 App（SwiftUI 单 Window 场景的默认）：工程、AI 打开的文件夹全没了" >&2
  exit 1
fi
if [ "$(grep -c 'return launched ? MCPBridge.addingNote(MCPBridge.relaunchNote, to: result) : result' Sources/SrtFlowMCP/AppConnection.swift || true)" -ne 1 ] \
   || [ "$(grep -c 'return (fd, true)' Sources/SrtFlowMCP/AppConnection.swift || true)" -ne 1 ]; then
  echo "✗ 小程序把 App 拉起来之后没在结果里告诉 AI（之前打开的工程、文件夹都不在了）" >&2
  exit 1
fi
echo "   ✓ 关窗口不退出；拉起 App 的那一次结果带 relaunchNote"

# 合成音效（docs/architecture/sound-effect-synth.md）：合成器和工具自己不碰 AVAudioFile（写文件只经 AIAudioFileWriter，同配音）；
# 渲染 + 写盘在 MediaReadQueue.analysis 上跑，不占 Swift 并发的线程池。
SFX_WRITERS="$(grep -l 'AVAudioFile' Sources/SrtFlow/SoundEffects/*.swift Sources/SrtFlow/AISoundEffect*.swift || true)"
if [ -n "${SFX_WRITERS}" ]; then
  echo "✗ 音效的文件只能经 AIAudioFileWriter 写，这些文件自己碰了 AVAudioFile：${SFX_WRITERS}"
  exit 1
fi
if [ "$(grep -c 'MediaReadQueue.run(on: MediaReadQueue.analysis)' Sources/SrtFlow/AISoundEffectTool.swift || true)" -ne 1 ] \
   || [ "$(grep -c 'AIAudioFileWriter.writeSoundEffect(' Sources/SrtFlow/AISoundEffectTool.swift || true)" -ne 1 ]; then
  echo "✗ AISoundEffectTool 要在 MediaReadQueue.analysis 上渲染并经 AIAudioFileWriter.writeSoundEffect 写文件"
  exit 1
fi
echo "   ✓ 合成音效：写文件只经 AIAudioFileWriter，渲染在 MediaReadQueue 上"

echo "==> swift build ${ARCH_FLAG}（小程序 + SrtFlowCore）"
# SwiftPM 的编译诊断走 stdout：静默成功可以，失败必须倾倒完整输出。
BUILD_OUT="$(swift build ${ARCH_FLAG} --product srtflow-mcp 2>&1)" || { printf '%s\n' "${BUILD_OUT}"; exit 1; }
BUILD_OUT="$(swift build ${ARCH_FLAG} --target SrtFlowCore 2>&1)" || { printf '%s\n' "${BUILD_OUT}"; exit 1; }
BUILD_OUT="$(swift build ${ARCH_FLAG} --target SrtFlowKokoro 2>&1)" || { printf '%s\n' "${BUILD_OUT}"; exit 1; }
BUILD_DIR="$(swift build ${ARCH_FLAG} --show-bin-path)"

OUT="$(mktemp -d)/mcpcheck"
trap 'rm -rf "$(dirname "$OUT")"' EXIT

echo "==> 编译自检二进制"
xcrun swiftc \
  -target "$TRIPLE" \
  -wmo \
  -I "$BUILD_DIR/Modules" \
  -o "$OUT" \
  Sources/SrtFlow/VideoEditModels.swift \
  Sources/SrtFlow/VideoEditCanvasRatio.swift \
  Sources/SrtFlow/StillAlphaNaming.swift \
  Sources/SrtFlow/VideoEditMediaReferences.swift \
  Sources/SrtFlow/VideoEditClipUpscale.swift \
  Sources/SrtFlow/VideoEditClipUpscaleRecord.swift \
  Sources/SrtFlow/VideoEditTrackSlot.swift \
  Sources/SrtFlow/VideoEditClipCrop.swift \
  Sources/SrtFlow/VideoEditShapeModels.swift \
  Sources/SrtFlow/VideoEditShapeAnimation.swift \
  Sources/SrtFlow/VideoEditShapeOutline.swift \
  Sources/SrtFlow/VideoEditShapePNGRenderer.swift \
  Sources/SrtFlow/VideoEditSoundScene.swift \
  Sources/SrtFlow/PerfCounters.swift \
  Sources/SrtFlow/VideoEditVolumeCurve.swift \
  Sources/SrtFlow/VideoEditFilterModels.swift \
  Sources/SrtFlow/VideoEditClipVisibility.swift \
  Sources/SrtFlow/VideoEditTransitionHandles.swift \
  Sources/SrtFlow/VideoEditFadeWindow.swift \
  Sources/SrtFlow/VideoEditAudioFade.swift \
  Sources/SrtFlow/VideoEditVideoFade.swift \
  Sources/SrtFlow/VideoEditClipAnimation.swift \
  Sources/SrtFlow/VideoEditClipAnimator.swift \
  Sources/SrtFlow/VideoEditTrackPalette.swift \
  Sources/SrtFlow/VideoEditTextStyle.swift \
  Sources/SrtFlow/VideoEditTextEasing.swift \
  Sources/SrtFlow/VideoEditTextAnimation.swift \
  Sources/SrtFlow/VideoEditTextAnimator.swift \
  Sources/SrtFlow/VideoEditTextNumber.swift \
  Sources/SrtFlow/VideoEditTextOdometer.swift \
  Sources/SrtFlow/VideoEditTextNumberRenderer.swift \
  Sources/SrtFlow/VideoEditTextModels.swift \
  Sources/SrtFlow/VideoEditTextRows.swift \
  Sources/SrtFlow/VideoEditTextLayout.swift \
  Sources/SrtFlow/VideoEditTextLayoutFonts.swift \
  Sources/SrtFlow/VideoEditTextRenderer.swift \
  Sources/SrtFlow/VideoEditTextDrawing.swift \
  Sources/SrtFlow/VideoEditClipMarker.swift \
  Sources/SrtFlow/VideoEditAnimation.swift \
  Sources/SrtFlow/VideoEditKeyframeEasing.swift \
  Sources/SrtFlow/VideoEditTimelineEdits.swift \
  Sources/SrtFlow/FreezeSliver.swift \
  Sources/SrtFlow/VideoEditSubtitleDocuments.swift \
  Sources/SrtFlow/VideoEditTimelineLinkage.swift \
  Sources/SrtFlow/VideoEditTimelineLinkageLanding.swift \
  Sources/SrtFlow/VideoEditTimelineSnap.swift \
  Sources/SrtFlow/VideoEditTimelineTrim.swift \
  Sources/SrtFlow/VideoEditMediaImport.swift \
  Sources/SrtFlow/VideoEditFormatVersion.swift \
  Sources/SrtFlow/MediaProbe.swift \
  Sources/SrtFlow/OptimizedMedia/MediaKeyframeProbe.swift \
  Sources/SrtFlow/AppLanguage.swift \
  Sources/SrtFlow/AIToolIO.swift \
  Sources/SrtFlow/AIShortIDs.swift \
  Sources/SrtFlow/AITimelineSummary.swift \
  Sources/SrtFlow/AITextEdits.swift \
  Sources/SrtFlow/AITextNumberChange.swift \
  Sources/SrtFlow/AIRecipe.swift \
  Sources/SrtFlow/AIRecipeStore.swift \
  Sources/SrtFlow/AIRecipeTools.swift \
  Sources/SrtFlow/AIVoiceChoice.swift \
  Sources/SrtFlow/AIVoiceRole.swift \
  Sources/SrtFlow/AIFalVoices.swift \
  Sources/SrtFlow/Fal/FalOutputs.swift \
  Sources/SrtFlow/Fal/FalModels.swift \
  Sources/SrtFlow/Fal/FalUpscaleModels.swift \
  Sources/SrtFlow/Fal/FalJobPhase.swift \
  Sources/SrtFlow/Upscale/UpscaleRange.swift \
  Sources/SrtFlow/AIUpscaleNames.swift \
  Sources/SrtFlow/KokoroVoicePieces.swift \
  Sources/SrtFlow/KokoroVoicePadding.swift \
  Sources/SrtFlow/KokoroVoiceAssembly.swift \
  Sources/SrtFlow/KokoroVoiceManifest.swift \
  Sources/SrtFlow/AIVoiceWords.swift \
  Sources/SrtFlow/AIVoiceLevel.swift \
  Sources/SrtFlow/AIAudioFileWriter.swift \
  Sources/SrtFlow/SoundEffects/SoundEffectDSP.swift \
  Sources/SrtFlow/SoundEffects/SoundEffectBuffer.swift \
  Sources/SrtFlow/AudioKWeighting.swift \
  Sources/SrtFlow/SoundEffects/SoundEffectReverb.swift \
  Sources/SrtFlow/SoundEffects/SoundEffectPreset.swift \
  Sources/SrtFlow/SoundEffects/SoundEffectClipGain.swift \
  Sources/SrtFlow/SoundEffects/SoundEffectAirPresets.swift \
  Sources/SrtFlow/SoundEffects/SoundEffectHitPresets.swift \
  Sources/SrtFlow/SoundEffects/SoundEffectTonePresets.swift \
  Sources/SrtFlow/AISoundEffectRequest.swift \
  Sources/SrtFlow/AIVoiceoverPlacement.swift \
  Sources/SrtFlow/AIVoiceoverSubtitles.swift \
  Sources/SrtFlow/SubtitleGen/SubtitleLineFit.swift \
  Sources/SrtFlow/SubtitleFrameGeometry.swift \
  Sources/SrtFlow/SubtitleFontScale.swift \
  Sources/SrtFlow/SubtitleFallbackFont.swift \
  Sources/SrtFlow/AITimelineEdits.swift \
  Sources/SrtFlow/VideoEditLinkRegrouping.swift \
  Sources/SrtFlow/AIClipEdit.swift \
  Sources/SrtFlow/AIFrameFit.swift \
  Sources/SrtFlow/AIFollowSubject.swift \
  Sources/SrtFlow/AIShotDetector.swift \
  Sources/SrtFlow/AIFramingRequest.swift \
  Sources/SrtFlow/AIClipDetails.swift \
  Sources/SrtFlow/AITrackSettings.swift \
  Sources/SrtFlow/AIKeyframes.swift \
  Sources/SrtFlow/AIShapeEdits.swift \
  Sources/SrtFlow/AIDuplicate.swift \
  Sources/SrtFlow/AIMusicCredits.swift \
  Sources/SrtFlow/AudioLibraryManifest.swift \
  Sources/SrtFlow/AIEncodeOptions.swift \
  Sources/SrtFlow/AITranscriptFormat.swift \
  Sources/SrtFlow/AIHarvestFailure.swift \
  Sources/SrtFlow/SubtitleGen/LanguageUndetectedError.swift \
  Sources/SrtFlow/AudioBeatTracker.swift \
  Sources/SrtFlow/AIBeatAnalysisWindow.swift \
  Sources/SrtFlow/AISpeechCuts.swift \
  Sources/SrtFlow/AIBeatCuts.swift \
  Sources/SrtFlow/VideoEditClipboardPayload.swift \
  Sources/SrtFlow/VideoEditClipboardPaste.swift \
  Sources/SrtFlow/VideoEditClipboardLanes.swift \
  Sources/SrtFlow/AIBlackBars.swift \
  Sources/SrtFlow/AISubjectFocus.swift \
  Sources/SrtFlow/AITextRegions.swift \
  Sources/SrtFlow/AICoverBox.swift \
  Sources/SrtFlow/AIVision.swift \
  Sources/SrtFlow/MediaReadQueue.swift \
  Sources/SrtFlow/AIContactSheet.swift \
  Sources/SrtFlow/AIFrameDescription.swift \
  Sources/SrtFlow/AIAudioLevels.swift \
  Sources/SrtFlow/AIDocumentReader.swift \
  Sources/SrtFlow/AIFileOperations.swift \
  Sources/SrtFlow/AIFinderSelection.swift \
  Sources/SrtFlow/VideoEditWaveformData.swift \
  Sources/SrtFlow/VideoEditWaveformPower.swift \
  Sources/SrtFlow/VideoEditPlacementDefault.swift \
  Sources/SrtFlow/AISubtitleEdits.swift \
  Sources/SrtFlow/AISubtitleStyle.swift \
  Sources/SrtFlow/AIClientConfigFiles.swift \
  Sources/SrtFlow/AIReadGrants.swift \
  Sources/SrtFlow/AIUndoGrouping.swift \
  Sources/SrtFlow/AITextLanguage.swift \
  Sources/SrtFlow/AIScreenRecordingRequest.swift \
  Sources/SrtFlow/AIScreenSourceMatch.swift \
  Sources/SrtFlow/DefaultFolder.swift \
  checks/MCP/main.swift \
  checks/MCP/Harness.swift \
  checks/MCP/ProtocolChecks.swift \
  checks/MCP/CatalogTextChecks.swift \
  checks/MCP/TimelineChecks.swift \
  checks/MCP/ConfigChecks.swift \
  checks/MCP/ReadGrantChecks.swift \
  checks/MCP/UndoChecks.swift \
  checks/MCP/LanguageChecks.swift \
  checks/MCP/FolderChecks.swift \
  checks/MCP/FramingChecks.swift \
  checks/MCP/FollowChecks.swift \
  checks/MCP/BlackBarChecks.swift \
  checks/MCP/SubjectChecks.swift \
  checks/MCP/LookChecks.swift \
  checks/MCP/ShotChecks.swift \
  checks/MCP/ListenChecks.swift \
  checks/MCP/TextDecodingChecks.swift \
  checks/MCP/DocumentChecks.swift \
  checks/MCP/FileOperationChecks.swift \
  checks/MCP/FinderChecks.swift \
  checks/MCP/ClipDetailChecks.swift \
  checks/MCP/TrackKeyframeChecks.swift \
  checks/MCP/ShapeChecks.swift \
  checks/MCP/CoverChecks.swift \
  checks/MCP/TextPartChecks.swift \
  checks/MCP/RecipeChecks.swift \
  checks/MCP/RecipeSizeChecks.swift \
  checks/MCP/VoiceChecks.swift \
  checks/MCP/VoiceLevelChecks.swift \
  checks/MCP/SubtitleStyleChecks.swift \
  checks/MCP/TextScanChecks.swift \
  checks/MCP/KokoroChecks.swift \
  checks/MCP/DuplicateChecks.swift \
  checks/MCP/MusicLibraryChecks.swift \
  checks/MCP/EncodeChecks.swift \
  checks/MCP/TranscriptFormatChecks.swift \
  checks/MCP/BeatChecks.swift \
  checks/MCP/SpeechCutChecks.swift \
  checks/MCP/BeatCutChecks.swift \
  checks/MCP/ProviderChecks.swift \
  checks/MCP/UpscaleToolChecks.swift \
  checks/MCP/FalVoiceChecks.swift \
  checks/MCP/SoundEffectChecks.swift \
  checks/MCP/ScreenRecordingToolChecks.swift \
  "$BUILD_DIR"/SrtFlowCore.build/*.o \
  "$BUILD_DIR"/SrtFlowMCPKit.build/*.o \
  "$BUILD_DIR"/SrtFlowKokoro.build/*.o

echo "==> 运行"
SRTFLOW_MCP_HELPER="$BUILD_DIR/srtflow-mcp" "$OUT"
