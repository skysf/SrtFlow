import Foundation

// MARK: - 工具清单：生成素材（fal.ai，方案第六块）
//
// 管什么：generate_media 的说明文字和参数。**只在用户配了 fal 的 Key 时才列出来**（`MCPToolName.provider`，方案第 36 条）。
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
        default:
            preconditionFailure("\(name) is not a generation tool")
        }
    }
}
