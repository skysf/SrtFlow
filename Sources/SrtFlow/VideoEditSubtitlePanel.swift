import SwiftUI
import SrtFlowCore

/// 预览右边那一列字幕表：整份字幕看得见、可编辑，播放到哪句就滚到哪句
/// （2026-08-12 用户拍板的形态，与烧录页的字幕列同一心智）。
///
/// 和烧录页的 `SubtitleEditPanel` 长得像，但**绑的东西不同**，不能互相替代：
/// 那边编辑的是外挂字幕文件（`EncodeItem.burnIn` / 独立文件，有 Save 写回原文件），
/// 这里编辑的是**工程里的字幕轨**——改动只进工程（随自动保存落盘），要文件走
/// 导出面板的「Subtitle files」。所有写入经 `VideoEditProjectSubtitleLink`
/// 的合同入口，一次编辑 = 一步撤销。
///
/// 这一列是**第三个**编辑入口，另外两个是时间线双击 cue、预览双击字幕；三者共用
/// 同一份选择（`EditSelection`）与同一批合同，合同见
/// docs/architecture/subtitle-track-visibility-and-layout.md。
struct VideoEditSubtitlePanel: View {
    @ObservedObject var project: VideoEditProject
    @ObservedObject var clock: PlayerClock
    /// 打开生成/翻译面板 —— 那是另一件事（从音频识别、机器翻译），不塞进这一列。
    var onOpenGenerator: () -> Void = {}

    @State private var followsPlayback = true
    /// 哪个格子有光标。**焦点归这一列持有**：行是会被重建的临时值，
    /// 从行内部给自己上焦点写不进去（见 `SubtitleFieldFocus` 的说明）。
    @FocusState private var focusedField: SubtitleFieldFocus?

    /// 新建一行的默认时长。分段器的常见句长在 1–3 秒，2 秒进去以后再拖时间线
    /// 或改时间码都容易。
    private static let newCueDuration: TimeInterval = 2

    private var cues: [SubtitleCue] { project.state.subtitle?.cues ?? [] }

    private var translationCues: [SubtitleCue] {
        project.state.subtitleCompanion?.translation?.cues ?? []
    }

    private var canEditOriginal: Bool { !project.state.subtitleHidden }
    private var canEditTranslation: Bool { project.state.hasVisibleTranslation }
    private var hasTranslationTrack: Bool {
        project.state.subtitleCompanion?.translation != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if cues.isEmpty {
                emptyState
            } else {
                table
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 顶部

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "captions.bubble")
                    .foregroundStyle(.secondary)
                Text("Subtitles")
                    .fontWeight(.semibold)
                Spacer(minLength: 6)
                if !cues.isEmpty {
                    Text(String(format: L10n("%d lines"), cues.count))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Button(action: onOpenGenerator) {
                    Image(systemName: "waveform.and.mic")
                }
                .buttonStyle(.borderless)
                .instantHelp("Generate or translate subtitle tracks")
                Button {
                    project.showsSubtitleList = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .instantHelp("Close the subtitle list and show the inspector")
            }

            if !cues.isEmpty {
                HStack(spacing: 8) {
                    Button(action: addCue) { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        // 新增只写**原文轨**（合同 7），而且新行的光标要落在原文
                        // 那一格 —— 原文轨藏着时既违反「隐藏 = 不可编辑」，
                        // 也没有那个输入框可以聚焦，接着打的字会被当成快捷键
                        //（空格播放、V 切眼睛、M 打标记）。所以直接置灰（复审 P2）。
                        .disabled(!canEditOriginal)
                        .instantHelp("Add a line at the playhead")
                    Button(action: removeSelected) { Image(systemName: "minus") }
                        .buttonStyle(.borderless)
                        .disabled(project.selectedSubtitleCueIDs.isEmpty || !canEditAnything)
                        .instantHelp("Delete the selected lines")
                    Button(action: splitSelected) { Image(systemName: "square.split.2x1") }
                        .buttonStyle(.borderless)
                        .disabled(project.selectedSubtitleCueID == nil || !canEditAnything)
                        .instantHelp("Break the selected line in two")
                    Button(action: mergeSelected) { Image(systemName: "arrow.triangle.merge") }
                        .buttonStyle(.borderless)
                        .disabled(project.selectedSubtitleCueIDs.count < 2 || !canEditAnything)
                        .instantHelp("Join the selected lines into one")

                    Spacer(minLength: 4)

                    // 两只眼睛就在手边：这一列会照着它们置灰输入框，
                    // 用户得能当场把轨放出来，而不是被一列点不动的框挡住。
                    Button {
                        project.toggleSubtitleHidden()
                    } label: {
                        Image(systemName: project.state.subtitleHidden ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .instantHelp("Hide or show the original subtitle track")
                    if hasTranslationTrack {
                        Button {
                            project.toggleTranslationHidden()
                        } label: {
                            Image(systemName: project.state.translationHidden
                                ? "character.bubble.fill" : "character.bubble")
                        }
                        .buttonStyle(.borderless)
                        .instantHelp("Hide or show the translated subtitle track")
                    }
                    Toggle(isOn: $followsPlayback) {
                        Image(systemName: "text.line.last.and.arrowtriangle.forward")
                    }
                    .toggleStyle(.button)
                    .buttonStyle(.borderless)
                    .instantHelp("Scroll to the line being spoken during playback")
                }
                if !canEditAnything {
                    Text("Every subtitle track is hidden — turn an eye back on to edit.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var canEditAnything: Bool { canEditOriginal || canEditTranslation }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "captions.bubble")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text("The subtitle lines show up here, in step with playback.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Add Subtitle File…", action: pickSubtitle)
                .controlSize(.small)
                .instantHelp("Open an .srt or .vtt file to edit")
            Button("Write One Line", action: addCue)
                .controlSize(.small)
                .disabled(!canEditOriginal)
                .instantHelp("Start a subtitle track by hand, at the playhead")
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
    }

    // MARK: - 字幕表

    /// 播放头此刻落在哪条上。重叠时取合同序最后一条 —— 与画面叠层最上面那行
    /// （`SubtitleOverlap.active` 的末条）是同一条。
    private var currentCueID: UUID? {
        SubtitleOverlap.active(at: clock.displayTime, in: cues).last?.id
    }

    private var table: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(cues) { cue in
                        // 身份就是 cue.id：行里已经没有本地草稿要重建（草稿在工程
                        // 上），拿文本当身份只会让每次提交都重建一次行、顺带丢焦点。
                        // 它同时是跟随播放滚动的锚点。
                        row(cue).id(cue.id)
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 6)
            }
            .onChange(of: currentCueID) { _, newID in
                guard followsPlayback, clock.isPlaying, let newID else { return }
                withAnimation { proxy.scrollTo(newID, anchor: .center) }
            }
            // 在时间线或预览里选中一条，这一列要跟着滚过去并高亮 ——
            // 三个入口同一份选择，看到的东西必须一致。
            .onChange(of: project.selectedSubtitleCueID) { _, newID in
                guard let newID else { return }
                withAnimation { proxy.scrollTo(newID, anchor: .center) }
            }
        }
    }

    private func row(_ cue: SubtitleCue) -> some View {
        VideoEditSubtitleCueRow(
            project: project,
            cue: cue,
            meta: project.state.subtitleCompanion?.cueMeta[cue.id],
            isCurrent: cue.id == currentCueID,
            isSelected: project.selectedSubtitleCueIDs.contains(cue.id),
            canEditOriginal: canEditOriginal,
            canEditTranslation: canEditTranslation,
            onSelect: { select(cue) },
            focusedField: $focusedField
        )
    }

    // MARK: - 动作

    /// 点行 = 选中它 + 把播放头带进这条（与时间线上点 cue 块同一语义：
    /// 核对一句字幕最快的方式就是看它）。
    private func select(_ cue: SubtitleCue) {
        project.selectSubtitleCue(cue.id)
        clock.seek(to: cue.start + 0.05)
    }

    private func addCue() {
        // 按钮已经置灰，这里再拦一道：合同只写原文轨，藏着就不该动它。
        guard canEditOriginal,
              let id = project.linkedInsertCue(at: clock.time, duration: Self.newCueDuration) else {
            return
        }
        project.selectSubtitleCue(id)
        project.showsSubtitleList = true
        // 新行这一拍还没装进响应链，当拍给焦点会被丢掉；隔一拍再放光标。
        // 不放的话按了 + 像什么也没发生（新行是空文本），接着打的字还会被
        // 当成快捷键吃掉。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            focusedField = .original(id)
        }
    }

    private func removeSelected() {
        let ids = project.selectedSubtitleCueIDs
        guard !ids.isEmpty else { return }
        project.linkedRemoveCues(ids: ids)
    }

    private func splitSelected() {
        guard let id = project.selectedSubtitleCueID,
              let cue = cues.first(where: { $0.id == id }) else { return }
        // 播放头落在这条里面就按播放头拆（那是用户看着画面挑的点），
        // 否则退回中点。
        let time = clock.time
        let at = (time > cue.start && time < cue.end) ? time : (cue.start + cue.end) / 2
        project.linkedSplitCue(id: id, at: at)
    }

    private func mergeSelected() {
        let ids = project.selectedSubtitleCueIDs
        guard ids.count >= 2 else { return }
        project.linkedMergeCues(ids: ids)
    }

    private func pickSubtitle() {
        let urls = FilePicker.chooseFiles(types: SubtitleFileTypes.readable, allowsMultiple: false)
        guard let url = urls.first else { return }
        project.attachSubtitle(url)
    }
}
