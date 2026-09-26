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
///
/// 2026-09-26 起原文、译文是两条独立的轨：**一张表按时间交错排**，行首标出是哪条轨，
/// 一行一句；加行加到选中那句所在的轨（没选中时加到原文轨）—— 计划 S12。
struct VideoEditSubtitlePanel: View {
    let project: VideoEditProject
    /// 播放器时钟：**持有不订阅**。这一列要跟着播放高亮「正在说的那句」，可一句通常好几秒 ——
    /// 订阅时钟就是整张表（每一行连同输入框）一秒重算二十遍。改成只在换句时写 `currentCueID`
    /// （docs/architecture/preview-perf-ratchet.md 第十二节）。
    let clock: PlayerClock
    /// 打开生成/翻译面板 —— 那是另一件事（从音频识别、机器翻译），不塞进这一列。
    var onOpenGenerator: () -> Void = {}

    @State private var followsPlayback = true
    /// 播放头（悬停预览时是影子播放头）此刻落在哪几句上（两条轨都算）。只在换句时写（`followCurrentCue`）。
    @State private var currentCueIDs: Set<UUID> = []
    /// 哪一句有光标。**焦点归这一列持有**：行是会被重建的临时值，
    /// 从行内部给自己上焦点写不进去（见 `VideoEditSubtitleCueRow` 的说明）。
    @FocusState private var focusedCueID: UUID?

    /// 新建一行的默认时长。分段器的常见句长在 1–3 秒，2 秒进去以后再拖时间线
    /// 或改时间码都容易。
    private static let newCueDuration: TimeInterval = 2

    /// 表里的全部行：两条轨的句子按时间交错排（起点相同时原文在前）。
    private var rows: [(cue: SubtitleCue, track: SubtitleTrack)] {
        let original = project.state.subtitleCues(of: .original).map { (cue: $0, track: SubtitleTrack.original) }
        let translation = project.state.subtitleCues(of: .translation).map { (cue: $0, track: SubtitleTrack.translation) }
        return (original + translation).enumerated()
            .sorted { $0.element.cue.start == $1.element.cue.start ? $0.offset < $1.offset : $0.element.cue.start < $1.element.cue.start }
            .map(\.element)
    }

    private var canEditOriginal: Bool { project.state.canEditSubtitleTrack(.original) || project.state.subtitle == nil }
    private var hasTranslationTrack: Bool {
        project.state.subtitleCompanion?.translation != nil
    }

    /// 加行加到哪条轨：选中那几句都在同一条轨上就是那条，否则原文轨。
    private var insertTrack: SubtitleTrack {
        let tracks = Set(project.selectedSubtitleCueIDs.compactMap { project.state.subtitleTrack(of: $0) })
        return tracks.count == 1 ? tracks.first! : .original
    }

    /// 选中的几句能合并：至少两句、都在同一条轨上、那条轨看得见。
    private var canMergeSelection: Bool {
        let ids = project.selectedSubtitleCueIDs
        let tracks = Set(ids.compactMap { project.state.subtitleTrack(of: $0) })
        guard ids.count >= 2, tracks.count == 1, let track = tracks.first else { return false }
        return project.state.canEditSubtitleTrack(track)
    }

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        VStack(spacing: 0) {
            header
            Divider()
            if project.state.allSubtitleCues.isEmpty {
                emptyState
            } else {
                table
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 哪句是「正在说的」：时钟每一跳只比一次，换了句才写 @State（整张表才重算）。
        // `$time` / `$peekTime` 在赋值之前发（willSet）：参数是新值，另一个读现值。
        .onReceive(clock.$time) { followCurrentCue(at: clock.peekTime ?? $0) }
        .onReceive(clock.$peekTime) { followCurrentCue(at: $0 ?? clock.time) }
        .onChange(of: project.state.allSubtitleCues) { _, _ in followCurrentCue(at: clock.displayTime) }
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
                if !project.state.allSubtitleCues.isEmpty {
                    Text(String(format: L10n("%d lines"), project.state.allSubtitleCues.count))
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

            if !project.state.allSubtitleCues.isEmpty {
                HStack(spacing: 8) {
                    Button(action: addCue) { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        // 加到选中那句所在的轨，而且新行的光标要落进去 —— 那条轨藏着时既违反
                        // 「隐藏 = 不可编辑」，也没有输入框可以聚焦，接着打的字会被当成快捷键
                        //（空格播放、V 切段的显隐、M 打标记）。所以直接置灰（复审 P2）。
                        .disabled(!project.state.canEditSubtitleTrack(insertTrack))
                        .instantHelp("Add a line at the playhead, on the selected line’s track")
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
                        // 只合同一条轨上的（计划 S14）。
                        .disabled(!canMergeSelection)
                        .instantHelp("Join the selected lines into one (on the same track)")

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
                        // 画面上分开摆了之后，点一下合回去：译文叠回原文下面（计划 S9）。
                        Button(action: project.stackTranslationUnderOriginal) {
                            Image(systemName: "rectangle.stack")
                        }
                        .buttonStyle(.borderless)
                        .disabled(project.state.translationLayout == nil)
                        .instantHelp("Put the translation back under the original on the video")
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

    private var canEditAnything: Bool {
        project.state.canEditSubtitleTrack(.original) || project.state.canEditSubtitleTrack(.translation)
    }

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

    /// 更新「播放头此刻落在哪几句上」（两条轨都算）。没换句不写。
    private func followCurrentCue(at time: Double) {
        let ids = Set(SubtitleOverlap.active(at: time, in: project.state.allSubtitleCues).map(\.id))
        if ids != currentCueIDs { currentCueIDs = ids }
    }

    /// 跟随播放时滚到哪一行：表里排在最前面的那句「正在说的」。
    private func firstCurrentRow() -> UUID? {
        rows.first { currentCueIDs.contains($0.cue.id) }?.cue.id
    }

    private var table: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(rows, id: \.cue.id) { row in
                        // 身份就是 cue.id（两条轨上互不相同）：行里已经没有本地草稿要重建（草稿在工程
                        // 上），拿文本当身份只会让每次提交都重建一次行、顺带丢焦点。
                        // 它同时是跟随播放滚动的锚点。
                        self.row(row.cue, track: row.track).id(row.cue.id)
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 6)
            }
            .onChange(of: currentCueIDs) { _, _ in
                guard followsPlayback, clock.isPlaying, let target = firstCurrentRow() else { return }
                withAnimation { proxy.scrollTo(target, anchor: .center) }
            }
            // 在时间线或预览里选中一条，这一列要跟着滚过去并高亮 ——
            // 三个入口同一份选择，看到的东西必须一致。
            .onChange(of: project.selectedSubtitleCueID) { _, newID in
                guard let newID else { return }
                withAnimation { proxy.scrollTo(newID, anchor: .center) }
            }
        }
    }

    private func row(_ cue: SubtitleCue, track: SubtitleTrack) -> some View {
        let companion = project.state.subtitleCompanion
        return VideoEditSubtitleCueRow(
            project: project,
            cue: cue,
            track: track,
            meta: track == .original ? companion?.cueMeta[cue.id] : nil,
            isStale: track == .translation
                && companion?.isTranslationStale(cue.id, original: project.state.subtitle) == true,
            isCurrent: currentCueIDs.contains(cue.id),
            isSelected: project.selectedSubtitleCueIDs.contains(cue.id),
            canEdit: project.state.canEditSubtitleTrack(track),
            onSelect: { select(cue) },
            focusedCueID: $focusedCueID
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
        // 按钮已经置灰，这里再拦一道：藏着的轨不该动它（还没有字幕轨时加到新建的原文轨）。
        let track = project.state.subtitle == nil ? SubtitleTrack.original : insertTrack
        guard project.state.subtitle == nil || project.state.canEditSubtitleTrack(track),
              let id = project.insertSubtitleCue(at: clock.time, duration: Self.newCueDuration, into: track) else {
            return
        }
        project.selectSubtitleCue(id)
        project.showsSubtitleList = true
        // 新行这一拍还没装进响应链，当拍给焦点会被丢掉；隔一拍再放光标。
        // 不放的话按了 + 像什么也没发生（新行是空文本），接着打的字还会被
        // 当成快捷键吃掉。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            focusedCueID = id
        }
    }

    private func removeSelected() {
        let ids = project.selectedSubtitleCueIDs
        guard !ids.isEmpty else { return }
        project.removeSubtitleCues(ids: ids)
    }

    private func splitSelected() {
        guard let id = project.selectedSubtitleCueID,
              let cue = project.state.subtitleCue(id) else { return }
        // 播放头落在这条里面就按播放头拆（那是用户看着画面挑的点），
        // 否则退回中点。
        let time = clock.time
        let at = (time > cue.start && time < cue.end) ? time : (cue.start + cue.end) / 2
        project.splitSubtitleCue(id: id, at: at)
    }

    private func mergeSelected() {
        let ids = project.selectedSubtitleCueIDs
        guard canMergeSelection else { return }
        project.mergeSubtitleCues(ids: ids)
    }

    private func pickSubtitle() {
        let urls = FilePicker.chooseFiles(types: SubtitleFileTypes.readable, allowsMultiple: false)
        guard let url = urls.first else { return }
        project.attachSubtitle(url)
    }
}
