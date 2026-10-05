---
id: sci-fi
title: Sci-fi
use_for: Tech products, AI and future topics, space, cyberpunk cities, game promos.
---
# Sci-fi

- Shape: by platform, 16:9 or 9:16.
- Length: 30–60 s.

## The bar

A well-made game or tech-launch trailer: cold, precise, a mechanical rhythm; the interface graphics feel like instruments on
a display, not stickers on a video.

## Structure

1. 0–3 s, boot-up: black with a typewriter text ("SYSTEM ONLINE", a line of coordinates or a timecode), or one white flash
   (whiteFade 0.1 s) into the first shot.
2. The build: cold pictures, shots of 1.5–3 s with one or two eerie holds of 3–4 s, quick push transitions.
3. The climax: cuts speed up on the beat, with white flashes on the strong beats.
4. The end: 0.5 s of silence, then the title draws itself (strokeDraw) or wipes in on a boom, holds, then black.

## Pace and pictures

- Shots 1.5–3 s; 0.3–1 s in the climax.
- Transitions: mostly hard cuts; whiteFade (0.1–0.15 s) as a flash; pushLeft, pushUp or wipeLeft (at most 0.25 s).
  At most 3 white flashes in any 10 seconds (people sensitive to flashing light).
- Picture animation: now and then zoom or wipe entrances (0.3 s).
- Filter: cyberpunk neon; hard industrial coldIron; space and labs mistBlue or coldWhite.

## Text

- English DIN Condensed or DIN Alternate; HUD labels in the monospaced Menlo; Chinese PingFang SC light. Capitals, wide
  letter_spacing (10–30). Colours cyan #00E5FF or magenta #FF2BD6 (one of them for the whole video), and white.
- Small HUD labels in the corners (coordinates, a timecode, "REC"), font_size 28–36 on 16:9, 16–20 on 9:16; thin lines and outlined rectangles from
  set_shape (line_width 2–3) as a viewfinder; a translucent filled rectangle (e.g. #00E5FF33) as a panel behind a label.
- Numbers roll (set_text number) for countdowns and data.
- Title: strokeDraw needs an outline (stroke_color), or use wipe. Hold it at least 2 s.
- Subtitles: on when there is narration, white light text, no word highlight.

## Sound

- Music: find_audio "space", "electronic", "synth", "dark" or "tense".
- Voice: add_voiceover with zh_male or en_male (or zh_female_warm / en_female_warm) at speed 1.0, subtitles
  true. For an on-board-computer feel, give the voice clips the radio sound scene (edit_clip sound_scene kind radio).

## Sound effects

- UI beeps (beep, click, tick), whooshes and glitches come from add_clips sound_effect with hit_at on the cut or the
  on-screen event; a riser into the climax and a boom on the title; made on this Mac.

## Generated media (only if generate_media is among your tools)

- Space, city or cockpit shots the footage lacks: generate_media kind text_to_video (cold colours, slow push), 480p first.
- Music: kind music ("dark synth, tense, pulsing"). A boot-up hum or another real-world sound: kind sound_effect.

## Taste

- Precision: every HUD label sits on one grid (the same margins, labels lined up on the same x); animations are short
  (0.2–0.4 s) and land exactly on events.
- Frames before labels: lines and rectangles draw themselves first (set_shape animation_in draw, 0.3–0.5 s), then the label
  inside appears 0.1–0.2 s later (typewriter or fade).
- Contrast in pace: eerie holds, then bursts of very short cuts at the climax.
- One neon accent plus white; filter coldIron or mistBlue at 0.6–0.8 (neon only for a cyberpunk city).
- Sound design leads: a glitch, beep or click on each HUD event, a riser into the climax, a breath of silence, then the boom.

## Avoid

- A glitch on every cut; HUD graphics on every shot; a white flash on every beat.
- Cyan and magenta together; text with an outline, a shadow and a box at once.
- Bouncy, playful motion: in sci-fi things snap and lock into place.

## Checklist before export

- HUD text does not cover the subject.
- Count the white flashes.
- The title at the end holds at least 2 s.
- Then "Look again before export" in the shared rules.
