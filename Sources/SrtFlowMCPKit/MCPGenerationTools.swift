import Foundation

// MARK: - 工具清单：送 fal 的两个工具（generate_media 生成素材，方案第六块；upscale_clip 放大片段，2026-10-02）
//
// 管什么：这两个工具的说明文字和参数。**只在用户配了 fal 的 Key 时才列出来**（`MCPToolName.provider`，方案第 36 条）。
// upscale_clip 的档位 / 目标 / 范围走词表（MCPVocabulary，和 App 的类型对账）；做完直接换源（用户 2026-10-02 定）。
// 不管什么：怎么调 fal、怎么问用户花钱（App 里的 Sources/SrtFlow/Fal/）；配旁白（add_voiceover，有 Key 时它优先用 fal 的声音，
// 见 docs/architecture/fal-generation.md）。

enum MCPGenerationTools {
    static func definition(for name: MCPToolName) -> MCPToolDefinition {
        switch name {
        case .generateMedia:
            return MCPToolDefinition(
                .generateMedia, title: "Generate media",
                description: """
                Makes a new image, video clip, music or sound effect with the user's fal.ai account (paid; listed only because \
                the user added a fal.ai key in SrtFlow's settings). Not for subtitles (generate_subtitles), narration \
                (add_voiceover), effects add_clips sound_effect can make, or footage the user already has. One result per \
                call. It returns a job_id at once: wait with get_job (an image takes about 10 s, a sound effect 5 s, music 30 s, \
                a video 1–3 minutes); while it runs get_job shows phase (queued, processing, downloading), queue_position, \
                transfer_percent, phase_seconds and typical_seconds. The finished job has file (a path in the user's SrtFlow folder; put it on the timeline \
                with add_clips) and cost_usd. kind: image | text_to_video | image_to_video | music | sound_effect. Video: \
                MiniMax H3 Max, 5–15 s per clip with sound built in; resolution 480p (cheapest, for drafts), 768p (default) or \
                1080p; text_to_video takes aspect_ratio (default: the project's canvas); image_to_video takes image (the first \
                frame) and keeps its shape. Write prompts like a director: subject, action, camera, light, style. Music: style, \
                mood, instruments. Sound effect: describe the sound. Cost: the user set a daily limit. Within it SrtFlow just \
                makes it; when a call would go over it, or the model's price is not known, SrtFlow asks the user in its top \
                banner and the job shows waiting_for_user: tell the user to answer there and keep waiting. The result has \
                estimated_cost_usd: tell the user before you make several expensive clips. model: another fal.ai endpoint id \
                when the user names one (its price is not known, so SrtFlow asks each time); options: extra fields for that \
                model as a JSON object.
                """,
                input: MCPSchema.object([
                    "kind": MCPSchema.string("What to make.", oneOf: MCPVocabulary.generationKinds),
                    "prompt": MCPSchema.string("What it should look / sound like."),
                    "image": MCPSchema.string("image_to_video: the picture file to start from (a path in the user's folder)."),
                    "duration": MCPSchema.number("Seconds. Video 5–15 (default 5), music 3–600 (default 30), sound effect 0.5–180 (default 5).", minimum: 0.5, maximum: 600),
                    "resolution": MCPSchema.string("Video only.", oneOf: MCPVocabulary.videoResolutions),
                    "aspect_ratio": MCPSchema.string("Image and text_to_video (default: the canvas of the project).", oneOf: MCPVocabulary.generationAspects),
                    "instrumental": MCPSchema.boolean("Music only: no singing (default true)."),
                    "name": MCPSchema.string("A short file name (default: made from the prompt)."),
                    "model": MCPSchema.string("Another fal.ai endpoint id, e.g. owner/model-name. Its price is not known: SrtFlow asks the user each time."),
                    "options": MCPSchema.object([:], description: "Extra fields for the model, passed through as they are.")
                ], required: ["kind", "prompt"]),
                openWorld: true
            )
        case .upscaleClip:
            return MCPToolDefinition(
                .upscaleClip, title: "Upscale clip",
                description: """
                Sends one video clip's source file to fal.ai for a sharper, larger version (paid; listed only because the user \
                added a fal.ai key) and, when it is done, points every clip in this project that uses that file at the new one \
                (one undo step; the original file stays next to it and the user can compare or revert from the clip's context \
                menu). Use it when a clip's source_size (get_timeline) is below the canvas or the export size: plain scaling adds \
                no detail. It returns a job_id at once: wait with get_job, which shows phase (preparing, uploading, queued, \
                processing, downloading, finishing), queue_position, transfer_percent, phase_seconds and typical_seconds; a clip \
                takes 1–5 minutes. The finished job has replaced_ids, file, width, height and cost_usd. tier: bytedance-standard \
                (default; cheapest, about 2 min), bytedance-pro (10 times the price, about 5 min), topaz-precision (faithful, best \
                for real faces, about 1 min), topaz-generative (re-draws fur, leaves, water; 6 times the price, about 3 min), \
                flux-precise (about 2 min) and flux-creative (about 3 min; adds detail), both for clips up to 20 s. target: 1080p, \
                1440p or 2160p on the short side (default: what the canvas needs); a source already at or above it is refused. \
                range: clip (this clip's used part plus 1 s handles each side), longest (default when another clip uses more of \
                the same file: covers both), file (the whole file). Cost: within the user's daily limit SrtFlow just starts; when \
                a call would go over it, SrtFlow asks the user in its top banner and the job shows waiting_for_user: tell the user \
                to answer there and keep waiting. The result's estimated_cost_usd is what the user pays (fal rates as of \
                2026-10-02); tell the user before upscaling many clips.
                """,
                input: MCPSchema.object([
                    "clip_id": MCPSchema.string("The video clip whose source file to upscale (get_timeline)."),
                    "tier": MCPSchema.string("Which fal.ai model and mode (default bytedance-standard).", oneOf: MCPVocabulary.upscaleTiers),
                    "target": MCPSchema.string("Short side to reach (default: what the canvas needs).", oneOf: MCPVocabulary.upscaleTargets),
                    "range": MCPSchema.string(
                        "How much of the file to send (default: longest when another clip uses more of it, else clip).", oneOf: MCPVocabulary.upscaleRanges
                    )
                ], required: ["clip_id"]),
                openWorld: true
            )
        default:
            preconditionFailure("\(name) is not a generation tool")
        }
    }
}
