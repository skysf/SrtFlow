import Foundation

// MARK: - 给 AI 的总说明（MCP 的 `instructions`）
//
// 客户端会把它放进模型的上下文，所以写的是**所有工具共用的规矩**：怎么开始、时间和轨道怎么说、
// 什么时候必须回头问用户、用户按了停止怎么办。某一个工具自己的事写在它自己的说明里。
// 这些规矩背后的产品决定见 docs/plans/2026-09-27-mcp.md。

public enum MCPInstructions {
    public static let text = """
    SrtFlow is a video editor running on the user's Mac. These tools edit the project that is open in \
    SrtFlow's window, and the user watches each step happen there (the edited clip is selected and the \
    preview jumps to it).

    How to work:
    1. Start with open_folder on the folder the user named (it lists the media inside), or open_project / \
    new_project. Call get_status first if unsure what is open.
    2. Call get_timeline to see tracks, clips and their ids. Ids can be shortened as they are shown.
    3. Edit with add_clips, edit_clip, split_clip, delete_items, set_transition, set_text, set_filter, \
    set_canvas and the subtitle tools.
    4. export_video, then wait with get_job.

    Conventions: times are seconds on the timeline, except source_in/source_out which are seconds inside the \
    media file. V1 is the main video track, V2 and up are video tracks drawn above it, A1 and up are audio \
    tracks. x/y positions are fractions of the frame.

    Rules:
    - Every edit is one undo step in SrtFlow; the user can press Command-Z or ask you to call undo \
    (round=true undoes everything from this round of edits).
    - Subtitle generation, translation and export are jobs: they return a job id; call get_job with \
    wait_seconds instead of starting them again.
    - If a result has "status": "needs_confirmation", ask the user its question in your own words and only \
    call again with its confirm_token after the user agrees. Never guess or reuse a token.
    - If a result or a job carries "waiting_for_user", SrtFlow is waiting for the user to do something (for example \
    click Download in a macOS dialog). Tell the user exactly what it says right away, then keep waiting with get_job; \
    never just wait silently.
    - If a call fails because the user pressed Stop in SrtFlow, stop calling tools and ask the user what to do next.
    - Only use folders and files the user gave you or that these tools returned.
    """
}
