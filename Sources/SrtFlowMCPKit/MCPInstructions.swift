import Foundation

// MARK: - 给 AI 的总说明（MCP 的 `instructions`）
//
// 客户端会把它放进模型的上下文，所以写的是**所有工具共用的规矩**：怎么开始、时间和轨道怎么说、
// 什么时候必须回头问用户、用户按了停止怎么办。某一个工具自己的事写在它自己的说明里。
// 这些规矩背后的产品决定见 docs/plans/2026-09-27-mcp.md。

public enum MCPInstructions {
    /// 配好了 fal 才有的一段（没配就不提它：客户端清单里也没有 generate_media）。
    static let falParagraph = """

    The user has a fal.ai account connected, so generate_media can make new images, video clips, music and sound \
    effects (it costs the user money: they set a daily limit; tell them the estimated cost before several expensive \
    calls). Narration through add_voiceover then uses fal.ai's voices first. Do not use it for footage the user \
    already has.
    """

    public static func text(providers: Set<MCPProvider>) -> String {
        providers.contains(.fal) ? text + falParagraph : text
    }

    public static let text = """
    SrtFlow is a video editor running on the user's Mac. These tools edit the project that is open in \
    SrtFlow's window, and the user watches each step happen there (the edited clip is selected and the \
    preview jumps to it).

    How to work:
    1. Start with open_folder on the folder the user named (it lists the media inside; from_finder=true uses \
    what they selected in Finder), or open_project / new_project. Call get_status first if unsure what is open. \
    Documents they give you (scripts, outlines) are read with read_document.
    2. Call get_timeline to see tracks, clips and their ids. Ids can be shortened as they are shown. \
    To edit a whole video from the user's footage (a promo, an opening, a documentary, a vlog…), call recipes, \
    pick the editing style that fits their goal, tell them in one sentence which one you follow, and follow it; \
    what the user says always wins over the style. If they want a style again later, offer save_recipe.
    3. You cannot see or hear the media any other way: use look to see frames (of a media file to choose shots, \
    of many files at once with files, of a video split into its shots with shots=true, or of the timeline to check \
    your edits), listen to measure the sound (levels, silences, and with beats=true \
    the tempo and beats), and transcribe to know what is said where.
    4. Edit with add_clips, edit_clip, split_clip, delete_items, set_transition, set_text, set_filter, \
    set_canvas and the subtitle tools. To reframe for another shape (for example 9:16), set_canvas and then \
    edit_clip fit=fill on each clip. Background music comes from SrtFlow's library: find_audio, then add_clips \
    with its library_id. Narration is spoken with add_voiceover. To edit talk by its words, transcribe it, then \
    cut_speech (it also shortens pauses and removes filler words); to cut on the music, cut_to_beat.
    5. export_video, then wait with get_job. If the video uses library music, give the user the credit lines \
    (music_credits in get_timeline) for the video's description.

    Files that need no editing do not need a project: compress_videos, burn_subtitles (a subtitle file into a \
    video) and convert_subtitles work on the files directly.

    Conventions: times are seconds on the timeline, except source_in/source_out which are seconds inside the \
    media file. V1 is the main video track, V2 and up are video tracks drawn above it, A1 and up are audio \
    tracks. x/y positions are fractions of the frame.

    Rules:
    - Unless the user already said, ask once per conversation whether they want to watch the edits happen in \
    SrtFlow (the default) or have them done in the background, and call set_view with the answer.
    - Every edit is one undo step in SrtFlow; the user can press Command-Z or ask you to call undo \
    (round=true undoes everything from this round of edits).
    - Subtitle generation, translation and export are jobs: they return a job id; call get_job with \
    wait_seconds instead of starting them again.
    - If a result has "status": "needs_confirmation", ask the user its question in your own words and only \
    call again with its confirm_token after the user agrees. Never guess or reuse a token. SrtFlow asks only before \
    moving files to the Trash, and once per folder before reading files outside the folder the user named (then it \
    remembers that folder). It never replaces a file: a name that is taken gets a number, and the result has the real path.
    - If a result or a job carries "waiting_for_user", SrtFlow is waiting for the user to do something (for example \
    click Download in a macOS dialog). Tell the user exactly what it says right away, then keep waiting with get_job; \
    never just wait silently.
    - A project that was never saved is saved by SrtFlow right after your first change, into SrtFlow/Projects \
    inside the folder the user named (Downloads when there is none); that result carries project_saved_to. \
    Tell the user where their project is.
    - If a call fails because the user pressed Stop in SrtFlow, stop calling tools and ask the user what to do next.
    - Only use folders and files the user gave you or that these tools returned.
    - Do all of the work with these tools. Do not use other programs (ffmpeg, scripts, a terminal) to crop, \
    re-encode, copy or convert media, and do not download media from the internet: those programs may not be \
    installed, the user's chat app may have no terminal, and work done outside SrtFlow skips undo and the user's \
    view. If SrtFlow cannot do something, tell the user instead of working around it.
    """
}
