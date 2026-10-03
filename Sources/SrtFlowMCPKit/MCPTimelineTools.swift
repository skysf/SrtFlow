import Foundation

// MARK: - 工具说明：时间线（读、放素材、改片段、切、删、转场、文字、滤镜、画面比例）
//
// 管什么：这几样工具给 AI 看的说明文字和参数表。清单的总入口在 MCPToolCatalog.swift。

public enum MCPTimelineTools {
    static func definition(for name: MCPToolName) -> MCPToolDefinition {
        switch name {
        case .getTimeline:
            return MCPToolDefinition(
                .getTimeline, title: "Read the timeline",
                description: """
                The whole timeline of the open project: every track and clip with its id (short; use it as shown), \
                start/end on \
                the timeline, source in/out in the file, speed, volume and transitions; texts; filters; subtitle \
                tracks; canvas \
                size and frame rate; music_credits for library music. Call it before editing and whenever you need fresh ids.
                """,
                readOnly: true
            )
        case .addClips:
            return addClips
        case .editClip:
            return editClip
        case .setKeyframes:
            return MCPToolDefinition(
                .setKeyframes, title: "Keyframes",
                description: """
                Animate a video or image clip over time: position (x/y = centre on the frame, 0–1), scale (1 = the \
                whole picture \
                just fits the frame, as in edit_clip), rotation (degrees) and opacity (0–1). Each list replaces that \
                property's \
                keyframes; [] removes them (the clip keeps its static values). Times are timeline seconds inside the \
                clip, or \
                fractions 0–1 of it with relative=true; each move eases in and out unless easing says otherwise. A \
                slow zoom: \
                relative=true, scale [{time: 0, value: 1}, {time: 1, value: 1.15}]. Keyframed position or scale blocks \
                edit_clip's fit/x/y/scale until removed.
                """,
                input: MCPSchema.object([
                    "clip_id": MCPSchema.string("Clip id from get_timeline."),
                    "relative": MCPSchema.boolean("Times are fractions 0–1 of the clip instead of seconds."),
                    "easing": MCPSchema.string("Curve of every move: easeInOut (default), easeIn, easeOut, linear (constant speed).", oneOf: MCPVocabulary.keyframeEasings),
                    "position": MCPSchema.array(of: MCPSchema.object([
                        "time": MCPSchema.number("Timeline seconds.", minimum: 0),
                        "x": MCPSchema.number("Centre across, 0–1 on the frame (-2…3 for a picture bigger than the frame).", minimum: -2, maximum: 3),
                        "y": MCPSchema.number("Centre down, same range.", minimum: -2, maximum: 3)
                    ], required: ["time", "x", "y"]), "Position."),
                    "scale": MCPSchema.array(of: MCPSchema.object([
                    "time": MCPSchema.number("Timeline seconds.", minimum: 0),
                    "value": MCPSchema.number("Size, 1 = fits the frame.")
                ], required: ["time", "value"]), "Scale."),
                    "rotation": MCPSchema.array(of: MCPSchema.object([
                    "time": MCPSchema.number("Timeline seconds.", minimum: 0),
                    "degrees": MCPSchema.number("Clockwise degrees.")
                ], required: ["time", "degrees"]), "Rotation."),
                    "opacity": MCPSchema.array(of: MCPSchema.object([
                    "time": MCPSchema.number("Timeline seconds.", minimum: 0),
                    "value": MCPSchema.number("0 = invisible, 1 = solid.")
                ], required: ["time", "value"]), "Opacity.")
                ], required: ["clip_id"])
            )
        case .setTrack:
            return MCPToolDefinition(
                .setTrack, title: "Track settings",
                description: """
                Change a whole track: its fader (volume_db, on top of each clip's own volume) and whether it is \
                hidden (left out \
                of the preview and the export). track "master" is the fader after all tracks. Use it to duck music under a \
                voice-over or mute a whole track.
                """,
                input: MCPSchema.object([
                    "track": MCPSchema.string("V1, V2… / A1, A2…, or master."),
                    "volume_db": MCPSchema.number("Fader in dB, 0 = unchanged.", minimum: -60, maximum: 6.02),
                    "hidden": MCPSchema.boolean("Hide or show the whole track (not for master).")
                ], required: ["track"])
            )
        case .splitClip:
            return MCPToolDefinition(
                .splitClip, title: "Split clips",
                description: """
                Cut clips in two at a timeline time. Without clip_ids it cuts the V1 clip under that time. \
                Returns the ids of the new right-hand pieces.
                """,
                input: MCPSchema.object([
                    "time": MCPSchema.number("Timeline time in seconds where to cut.", minimum: 0),
                    "clip_ids": MCPSchema.array(of: MCPSchema.string("Clip id."), "Only cut these clips.")
                ], required: ["time"])
            )
        case .freezeFrame:
            return MCPToolDefinition(
                .freezeFrame, title: "Freeze frame",
                description: """
                Hold the picture: the clip is cut at that moment and a still of that frame is inserted for duration \
                seconds (default 2); later clips on the same track move right by that much (Linkage on: what sits on them \
                follows; off: other tracks stay). Without clip_id it freezes the V1 clip at that time. Not for \
                audio, images, hidden clips, or a moment \
                inside a V1 transition. The still is a PNG next to the project. To end on a clip's last frame, give a time \
                inside that frame: a leftover shorter than one frame is dropped, a longer one keeps playing after the still \
                (tail_id in the result).
                """,
                input: MCPSchema.object([
                    "time": MCPSchema.number("Timeline time of the frame to hold.", minimum: 0),
                    "clip_id": MCPSchema.string("The clip to freeze (default: the V1 clip at that time)."),
                    "duration": MCPSchema.number("Seconds to hold (default 2).", minimum: 0.2, maximum: 60)
                ], required: ["time"])
            )
        case .deleteItems:
            return MCPToolDefinition(
                .deleteItems, title: "Delete",
                description: """
                Delete clips, texts, filters or subtitle lines by id; kinds can be mixed. ripple=true closes the gaps this \
                leaves on V1 by moving the later V1 clips left. Linkage on: what sits on deleted or moved V1 clips follows; \
                off: other tracks stay.
                """,
                input: MCPSchema.object([
                    "ids": MCPSchema.array(of: MCPSchema.string("Id from get_timeline or get_subtitles."), "What to delete.", minItems: 1),
                    "ripple": MCPSchema.boolean("Close the gaps left on V1.")
                ], required: ["ids"]),
                destructive: true
            )
        case .duplicateItems:
            return MCPToolDefinition(
                .duplicateItems, title: "Duplicate",
                description: """
                Copy clips, texts, shapes, filters or subtitle lines (ids can be mixed) and place the copies with the same \
                spacing, the earliest at start (default: right after the last of them ends). Landing works like \
                paste: a clip \
                that would overlap goes up to the next free video track (or another audio track), groups keep their order, \
                linked audio comes along. track picks where a single group of clips goes. Returns the new ids.
                """,
                input: MCPSchema.object([
                    "ids": MCPSchema.array(of: MCPSchema.string("Id from get_timeline or get_subtitles."), "What to copy.", minItems: 1),
                    "start": MCPSchema.number("Timeline time for the earliest copy.", minimum: 0),
                    "track": MCPSchema.string("V1, V2… or A1, A2…: where the copied clips should go.")
                ], required: ["ids"])
            )
        case .setTransition:
            return MCPToolDefinition(
                .setTransition, title: "Set a transition",
                description: """
                Set the transition between a V1 clip and the V1 clip right after it; the two must touch. \
                type none removes it. all=true applies it to every touching pair on V1.
                """,
                input: MCPSchema.object([
                    "after_clip_id": MCPSchema.string("The V1 clip before the cut."),
                    "all": MCPSchema.boolean("Apply to every touching pair of V1 clips."),
                    "type": MCPSchema.string("Transition.", oneOf: MCPVocabulary.transitions),
                    "duration": MCPSchema.number("Seconds (default 0.5).", minimum: 0.1, maximum: 3)
                ], required: ["type"])
            )
        case .setText:
            return setText
        case .setShape:
            return MCPToolDefinition(
                .setShape, title: "Shape",
                description: """
                Draw a line, rectangle, square, circle or arc over the video for a while (an outline to point at or frame something; \
                filled=true paints a solid block, e.g. letterbox bars or a colour panel behind a text), or change one when \
                shape_id is given; only the fields you pass change. x/y is the centre as fractions of the frame; \
                width (a line's \
                length) and height are fractions of the frame (a square, circle or arc uses width as its size). rotation turns \
                lines; on an arc it is where the arc starts, clockwise from 12 o'clock, and sweep is how far it goes. \
                line_width is \
                pixels on a 1080-high frame. Shapes are drawn under texts. kind=blur or mosaic draws nothing: it blurs or \
                pixelates the picture under it (hide a watermark or burned-in subtitles; look text_scan gives the values); \
                strength is the blur radius or mosaic cell in pixels on a 1080-high frame. animation_in / animation_out \
                make a shape fade, pop, wipe or draw itself in and out. Delete with delete_items.
                """,
                input: MCPSchema.object([
                    "shape_id": MCPSchema.string("Change this shape instead of adding one."),
                    "kind": MCPSchema.string("Shape (required when adding).", oneOf: ["line", "rectangle", "square", "circle", "arc", "blur", "mosaic"]),
                    "start": MCPSchema.number("Timeline start in seconds (default: the playhead).", minimum: 0),
                    "duration": MCPSchema.number("Seconds on screen (default 3).", minimum: 0.2),
                    "x": MCPSchema.number("Horizontal centre, 0–1.", minimum: 0, maximum: 1),
                    "y": MCPSchema.number("Vertical centre, 0–1.", minimum: 0, maximum: 1),
                    "width": MCPSchema.number("Width (or a line's length) as a fraction of the frame.", minimum: 0.02, maximum: 1),
                    "height": MCPSchema.number("Rectangle height as a fraction of the frame.", minimum: 0.02, maximum: 1),
                    "rotation": MCPSchema.number("Clockwise degrees: a line's angle (±90), or where an arc starts from 12 o'clock.", minimum: -360, maximum: 360),
                    "sweep": MCPSchema.number("Arcs only: degrees the arc covers, clockwise (default 270).", minimum: 1, maximum: 359),
                    "color": MCPSchema.string("#RRGGBB or #RRGGBBAA."),
                    "line_width": MCPSchema.number("Pixels on a 1080-high frame (default 6).", minimum: 1, maximum: 24),
                    "strength": MCPSchema.number("blur/mosaic only, pixels on a 1080-high frame (blur 28, mosaic 22).", minimum: 2, maximum: 80),
                    "filled": MCPSchema.boolean("Rectangles, squares and circles: solid instead of an outline."),
                    "animation_in": MCPSchema.string("Entrance; draw traces the outline from its start (a solid shape fills in that way).", oneOf: MCPVocabulary.shapeAnimations),
                    "animation_out": MCPSchema.string("Exit: the entrance played backwards.", oneOf: MCPVocabulary.shapeAnimations),
                    "animation_in_duration": MCPSchema.number("Entrance seconds (default 0.6).", minimum: 0.1, maximum: 5),
                    "animation_out_duration": MCPSchema.number("Exit seconds (default 0.6).", minimum: 0.1, maximum: 5),
                    "hidden": MCPSchema.boolean("Hide it without deleting it.")
                ])
            )
        case .setFilter:
            return MCPToolDefinition(
                .setFilter, title: "Filter",
                description: """
                Add a colour filter over a time range (it grades every video track there, not texts or subtitles), \
                or change one \
                when filter_id is given; only the fields you pass change. Presets: tealOrange (blockbuster teal \
                shadows, warm \
                skin), coldIron (cold, desaturated, hard, industrial), warmSun (warm golden daylight), flatGrey (flat \
                low-saturation documentary), nightGold (night with amber highlights, deep blacks), fadedFilm (old \
                faded film, \
                lifted blacks), coldWhite (bright clean cool whites: products, interiors), mistBlue (misty morning \
                blue, low \
                contrast), inkShadow (hard black and white), neon (cyberpunk magenta and cyan, full saturation).
                """,
                input: MCPSchema.object([
                    "filter_id": MCPSchema.string("Change this filter instead of adding one."),
                    "preset": MCPSchema.string("Look.", oneOf: MCPVocabulary.filterPresetIDs),
                    "start": MCPSchema.number("Timeline start in seconds (default: the playhead).", minimum: 0),
                    "duration": MCPSchema.number("Seconds (default 3).", minimum: 0.1),
                    "strength": MCPSchema.number("0 to 1 (default 1).", minimum: 0, maximum: 1),
                    "hidden": MCPSchema.boolean("Hide it without deleting it.")
                ])
            )
        case .setCanvas:
            return MCPToolDefinition(
                .setCanvas, title: "Canvas",
                description: """
                Set the output frame shape and/or frame rate. auto follows the first V1 clip; \
                9:16 is for TikTok, Reels and Shorts; 16:9 for YouTube. Clips keep their layout: to fill a new shape, \
                call edit_clip fit=fill on each clip.
                """,
                input: MCPSchema.object([
                    "ratio": MCPSchema.string("Frame shape.", oneOf: MCPVocabulary.canvasRatios),
                    "fps": MCPSchema.integer("Frames per second: 24, 30 or 60.", minimum: 24, maximum: 60)
                ])
            )
        default:
            preconditionFailure("\(name.rawValue) is described in another group")
        }
    }

    private static var addClips: MCPToolDefinition {
        let soundEffect = MCPSchema.object([
            "preset": MCPSchema.string(
                "whoosh (hit at 60%), swoosh (short, bright), suction (rises, stops dead: hit = end), riser (builds: hit = end), " +
                    "downlifter (low swell, falls), impact (long tail), boom (deep), hit, pop, click, tick, ding, " +
                    "sparkle (hit = first twinkle), beep, glitch, shutter.",
                oneOf: MCPVocabulary.soundEffectPresets
            ),
            "duration": MCPSchema.number("Seconds, 0.05-10 (default: the preset's own, 0.05-2).", minimum: 0.05, maximum: 10),
            "pitch": MCPSchema.number("Pitch multiplier 0.25-4 (default 1).", minimum: 0.25, maximum: 4),
            "brightness": MCPSchema.number("0 dark to 1 bright (default 0.5).", minimum: 0, maximum: 1),
            "size": MCPSchema.number("Space: 0 dry to 1 hall (default: the preset's own).", minimum: 0, maximum: 1),
            "variation": MCPSchema.integer("0-999: another take of the same sound.", minimum: 0, maximum: 999),
            "volume_db": MCPSchema.number("Clip volume in dB (default -8, under speech).", minimum: -60, maximum: 12)
        ], description: "Instead of file: a sound effect made on this Mac (no download, no fal); place it with hit_at.")
        let item = MCPSchema.object([
            "file": MCPSchema.string("Path of a video, image, audio or subtitle file (absolute, or relative to the opened folder)."),
            "library_id": MCPSchema.string("Instead of file: a music track id from find_audio (SrtFlow downloads it if needed)."),
            "sound_effect": soundEffect,
            "hit_at": MCPSchema.number(
                "For sound_effect or a library sound effect: the timeline second its loudest moment lands on (a cut, a word " +
                    "appearing); SrtFlow sets the start (overrides start). Default for sound_effect: the playhead.",
                minimum: 0
            ),
            "source_in": MCPSchema.number("Where to start in the file, seconds (default 0).", minimum: 0),
            "source_out": MCPSchema.number("Where to stop in the file, seconds (default: the end). For an image: how long it shows (default 5)."),
            "track": MCPSchema.string(MCPSchema.trackDescription),
            "start": MCPSchema.number("Timeline start in seconds.", minimum: 0)
        ])
        return MCPToolDefinition(
            .addClips, title: "Add clips",
            description: """
            Put media files, library audio (find_audio) or sound effects SrtFlow makes (sound_effect) on the timeline, in \
            the given order. Each item is a file, a library_id or a sound_effect, with the part to use \
            (source_in/source_out), the track and the start; a sound effect takes hit_at instead so its hit lands on a cut. \
            Without a start, video and images are appended after the last clip of their track (V1 by default) and audio \
            starts at 0 on the first free audio track. If the spot is taken, a video clip goes up to the next free video \
            track; insert=true instead pushes the later V1 clips right to make room. A subtitle file (.srt, .vtt, .ass) \
            becomes the subtitle track, replacing the current one. Files outside the opened folder need the user's OK. \
            Returns the new clip ids (hit_at for sound effects) and credit lines for library music.
            """,
            input: MCPSchema.object([
                "clips": MCPSchema.array(of: item, "Clips to add, in timeline order.", minItems: 1),
                "insert": MCPSchema.boolean("On V1 with a start time: push later V1 clips right instead of lifting to another track."),
                "confirm_token": MCPSchema.confirmToken
            ], required: ["clips"])
        )
    }

    private static var editClip: MCPToolDefinition {
        let crop = MCPSchema.object([
            "left": MCPSchema.number("Fraction of the source picture to cut from the left.", minimum: 0, maximum: 0.45),
            "right": MCPSchema.number("Fraction to cut from the right.", minimum: 0, maximum: 0.45),
            "top": MCPSchema.number("Fraction to cut from the top.", minimum: 0, maximum: 0.45),
            "bottom": MCPSchema.number("Fraction to cut from the bottom.", minimum: 0, maximum: 0.45)
        ], description: "Cut the edges of the source picture off (all 0 removes the crop).")
        return MCPToolDefinition(
            .editClip, title: "Change a clip",
            description: """
            Change one clip; only the fields you pass change. Move it (start, track), trim it (source_in/source_out are \
            seconds in the source file), or set speed, volume in dB, mute, hide, and audio fade in/out. A move or trim that \
            would overlap another clip on the same track fails and names that clip; ripple=true on V1 moves the later V1 \
            clips along instead. Picture (video and image clips): fit=fill fills the whole frame and cuts off what \
            sticks out. It aims at the subject SrtFlow finds in a few frames (faces, then \
            people, then text when there are no people, then whatever stands out; the result says what it found), at the \
            text only with focus=text (slides, screen recordings), or at \
            focus_x/focus_y; focus=center skips the search. When the subject moves, the crop follows it with a few position \
            keyframes (follow=false keeps one fixed crop). fit=fit shows the whole picture with bars (the default). fit \
            starts from the whole picture unless crop or remove_black_bars says which part to use; remove_black_bars=true \
            looks at a few frames and cuts off letterbox / pillarbox bars. Without fit, x/y/scale place the picture \
            yourself \
            (x/y: its centre as fractions of the frame; scale 1 = the whole picture just fits). The result's picture \
            block says whether the frame is filled. SrtFlow edits the clip, never the file. \
            Also: rotation, opacity, flips, entrance / exit animations, volume_curve, sound_scene, markers, keyframes; see each field.
            """,
            input: MCPSchema.object([
                "clip_id": MCPSchema.string("Clip id from get_timeline."),
                "start": MCPSchema.number("New timeline start, seconds.", minimum: 0),
                "track": MCPSchema.string(MCPSchema.trackDescription),
                "source_in": MCPSchema.number("New start inside the source file, seconds.", minimum: 0),
                "source_out": MCPSchema.number("New end inside the source file, seconds.", minimum: 0),
                "speed": MCPSchema.number("Playback speed, 1 = normal.", minimum: 0.1, maximum: 8),
                "volume_db": MCPSchema.number("Volume change in dB, 0 = original; with a volume_curve it shifts the whole curve.", minimum: -60, maximum: 6.02),
                "muted": MCPSchema.boolean("Silence the clip."),
                "hidden": MCPSchema.boolean("Hide the clip from preview and export without deleting it."),
                "fade_in": MCPSchema.number("Audio fade-in, seconds.", minimum: 0),
                "fade_out": MCPSchema.number("Audio fade-out, seconds.", minimum: 0),
                "fit": MCPSchema.string("fill: cover the whole frame; fit: show the whole picture.", oneOf: ["fill", "fit"]),
                "focus": MCPSchema.string("With fit=fill: aim at the subject (default), at the text, or the centre.", oneOf: ["subject", "text", "center"]),
                "focus_x": MCPSchema.number("With fit=fill: horizontal point of the source picture to keep centred, 0 = left edge.", minimum: 0, maximum: 1),
                "focus_y": MCPSchema.number("With fit=fill: vertical point to keep centred, 0 = top edge.", minimum: 0, maximum: 1),
                "follow": MCPSchema.boolean("With fit=fill aiming at the subject: follow it when it moves (default true)."),
                "crop": crop,
                "remove_black_bars": MCPSchema.boolean("Find black bars around the picture and cut them off (instead of crop)."),
                "x": MCPSchema.number("Horizontal centre of the picture on the frame, 0–1; a bigger picture needs values below 0 or above 1 (-2 to 3) to bring its edge into view.", minimum: -2, maximum: 3),
                "y": MCPSchema.number("Vertical centre of the picture on the frame, the same way (-2 to 3).", minimum: -2, maximum: 3),
                "scale": MCPSchema.number("Picture size, 1 = the whole picture just fits the frame.", minimum: 0.05, maximum: 6),
                "rotation": MCPSchema.number("Clockwise degrees.", minimum: -360, maximum: 360),
                "opacity": MCPSchema.number("0 = invisible, 1 = solid.", minimum: 0, maximum: 1),
                "flip_horizontal": MCPSchema.boolean("Mirror left-right."),
                "flip_vertical": MCPSchema.boolean("Mirror top-bottom."),
                "entrance": MCPSchema.string("How the picture comes in (a V1 transition replaces entrance / exit on its edge).", oneOf: MCPVocabulary.clipAnimations),
                "entrance_duration": MCPSchema.number("Seconds (default 0.6 when an entrance is chosen).", minimum: 0),
                "exit": MCPSchema.string("How the picture goes out.", oneOf: MCPVocabulary.clipAnimations),
                "exit_duration": MCPSchema.number("Seconds (default 0.6 when an exit is chosen).", minimum: 0),
                "animation_intensity": MCPSchema.number("How far rise / pop / zoom move, 0–1 (default 0.6).", minimum: 0, maximum: 1),
                "volume_curve": MCPSchema.array(of: MCPSchema.object([
                    "time": MCPSchema.number("Timeline seconds, inside the clip.", minimum: 0),
                    "db": MCPSchema.number("Volume there in dB.", minimum: -60, maximum: 6)
                ], required: ["time", "db"]), "Volume points in timeline seconds and dB, replacing the whole curve ([] removes it); straight lines between them."),
                "sound_scene": MCPSchema.object([
                    "kind": MCPSchema.string("Scene.", oneOf: MCPVocabulary.soundScenes),
                    "intensity": MCPSchema.number("How much of the effect, 0–1.", minimum: 0, maximum: 1),
                    "distortion": MCPSchema.number("Speaker scenes, 0–1.", minimum: 0, maximum: 1),
                    "tone": MCPSchema.number("Speaker scenes, 0–1.", minimum: 0, maximum: 1),
                    "room_size": MCPSchema.number("Room and outdoor scenes, 0–1.", minimum: 0, maximum: 1),
                    "distance": MCPSchema.number("Room and outdoor scenes, 0–1.", minimum: 0, maximum: 1)
                ], description: "A speaker (telephone, megaphone, radio: distortion, tone) or a place (the others: room_size, distance); kind none removes it."),
                "markers": MCPSchema.array(of: MCPSchema.object([
                    "time": MCPSchema.number("Timeline seconds, inside the clip.", minimum: 0),
                    "note": MCPSchema.string("Note shown on the marker."),
                    "color": MCPSchema.string("Colour.", oneOf: MCPVocabulary.markerColors)
                ], required: ["time"]), "This clip's markers (replaces all of them; [] removes them all)."),
                "ripple": MCPSchema.boolean("On V1: move the later V1 clips by the same amount the clip's end moves."),
                "keyframes": MCPSchema.string("keep_frames (default: motion stays on its source frames), stretch (re-timed to the new window) or clear.", oneOf: MCPVocabulary.keyframePolicies)
            ], required: ["clip_id"])
        )
    }

    private static var setText: MCPToolDefinition {
        MCPToolDefinition(
            .setText, title: "Text",
            description: """
            Add a text overlay, or change one when text_id is given; only the fields you pass change. The position is the \
            centre of the text block: a named spot, or x/y as fractions of the frame (x 0 = left, y 0 = top). Sizes are \
            pixels on a 1080-high frame. Colours are #RRGGBB or #RRGGBBAA. Long text wraps inside box_width.
            """,
            input: MCPSchema.object([
                "text_id": MCPSchema.string("Change this text instead of adding one."),
                "text": MCPSchema.string("The words; a newline (or the two characters \\n) starts a new line."),
                "start": MCPSchema.number("Timeline start in seconds (default: the playhead).", minimum: 0),
                "duration": MCPSchema.number("Seconds on screen (default 3).", minimum: 0.2),
                "position": MCPSchema.string("Named spot.", oneOf: MCPVocabulary.textPositions),
                "x": MCPSchema.number("Horizontal centre, 0–1.", minimum: 0, maximum: 1),
                "y": MCPSchema.number("Vertical centre, 0–1.", minimum: 0, maximum: 1),
                "box_width": MCPSchema.number("Wrap width as a fraction of the frame width (default 0.8).", minimum: 0.05, maximum: 1),
                "font": MCPSchema.string("Font family name, e.g. PingFang SC, Helvetica Neue, Avenir Next."),
                "font_size": MCPSchema.number("Pixels on a 1080-high frame (a 9:16 frame is 1920 high: 1.78x larger there); 44-52 fits 14 capitals on a line (default 96).", minimum: 12, maximum: 1000),
                "bold": MCPSchema.boolean("Bold."),
                "italic": MCPSchema.boolean("Italic."),
                "color": MCPSchema.string("Text colour."),
                "alignment": MCPSchema.string("Line alignment inside the block.", oneOf: MCPVocabulary.textAlignments),
                "stroke_color": MCPSchema.string("Outline colour; \"none\" removes the outline."),
                "stroke_width": MCPSchema.number("Outline width in pixels.", minimum: 0.5, maximum: 24),
                "shadow": MCPSchema.boolean("Soft drop shadow."),
                "background_color": MCPSchema.string("Box behind the text; \"none\" removes it."),
                "letter_spacing": MCPSchema.number("Extra space between letters, pixels (0 = normal).", minimum: -20, maximum: 80),
                "rotation": MCPSchema.number("Clockwise degrees.", minimum: -360, maximum: 360),
                "animation_in": MCPSchema.string("Entrance animation.", oneOf: MCPVocabulary.textAnimations),
                "animation_out": MCPSchema.string("Exit animation.", oneOf: MCPVocabulary.textAnimations),
                "animation_in_duration": MCPSchema.number("Entrance seconds (default 0.6).", minimum: 0),
                "animation_out_duration": MCPSchema.number("Exit seconds (default 0.6).", minimum: 0),
                "animation_intensity": MCPSchema.number("How far the animations move, 0–1 (default 0.6).", minimum: 0, maximum: 1),
                "emphasis": MCPSchema.string("Loops while on screen: breathe = a slight slow pulse.", oneOf: MCPVocabulary.textEmphasis),
                "number": MCPSchema.object([
                    "from": MCPSchema.number("Start value."),
                    "to": MCPSchema.number("End value."),
                    "decimals": MCPSchema.integer("Digits after the point (default 0).", minimum: 0, maximum: 4),
                    "thousands": MCPSchema.boolean("Group thousands with commas (default true)."),
                    "prefix": MCPSchema.string("Before the number, e.g. \"$\"."),
                    "suffix": MCPSchema.string("After the number, e.g. \"+\" or \" days\"."),
                    "style": MCPSchema.string("count counts up; odometer spins each digit.", oneOf: MCPVocabulary.numberStyles),
                    "seconds": MCPSchema.number("How long it rolls (default 1.5).", minimum: 0.1, maximum: 20),
                    "delay": MCPSchema.number("Seconds to wait before rolling.", minimum: 0, maximum: 60),
                    "remove": MCPSchema.boolean("true turns it back into plain text.")
                ], description: "Show a number rolling from one value to another instead of text (text is not needed); only the fields you pass change."),
                "hidden": MCPSchema.boolean("Hide it without deleting it.")
            ])
        )
    }
}
