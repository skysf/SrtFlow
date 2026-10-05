---
id: product-promo
title: Product or course promo
use_for: Selling a product, promoting a course or a service, app demos, live-stream highlights, unboxing that sells.
---
# Product or course promo

- Shape: 9:16 for short-video platforms, 16:9 for YouTube.
- Length: 15–30 s for short-video platforms; never more than 60 s.

## The bar

The best-performing short ads on Douyin and TikTok, cut with the care of an Apple product film: the result in the first
second, one clear message per beat, the product always at its best.

## Structure (30-second version)

1. 0–3 s, the hook: the result first — the best-looking finished product, a before/after, the most striking number, or one
   line that names the viewer's pain. A line of big text appears at the same time. Never open on a logo or a slow fade-in.
2. 3–8 s, the problem or the moment: why the viewer needs it.
3. 8–22 s, the selling points: 2–3 of them, each = one shot + one sentence + one line of big keyword text. Numbers roll
   (set_text number, 0 → the value in about 1 s).
4. 22–27 s, the proof: results, before/after, real reviews. Skip it when the footage has none; never invent it.
5. Last 3–5 s, the call to action: a general line such as "Tap the link on my profile to learn more"; hold the last frame at
   least 1.5 s.

## Pace and pictures

- Shots 1–3 s, about 2 s on average, never the same length three times in a row. Something must change every 2–3 s (a new
  shot, a picture zooming in, text appearing).
- Talking parts: cut_speech first — remove filler words, shorten pauses to 0.15–0.25 s.
- Transitions: mostly hard cuts; between parts now and then pushLeft or pushUp (at most 0.3 s, one direction for the whole
  video); one whiteFade flash (0.15 s) for revealing the finished product.
- Picture animation: key product shots enter with pop or zoom (0.3 s), at most one shot in three; a still product photo slowly
  grows with set_keyframes (scale 1 → 1.08 over the shot, the default easeInOut easing); the other shots hold or carry their
  own movement.
- Filter: products, interiors, clean looks → coldWhite; everyday life → warmSun. Strength 0.5–0.7, one filter for the whole video.

## Text

- Keyword text: Chinese PingFang SC bold; English Avenir Next bold (or Futura). font_size 44–52 on 9:16 (English capitals up to
  14 a line, Chinese up to 8), 90–110 on 16:9.
- White with a dark outline, or on a solid box (background_color) in the video's one accent colour. animation_in pop or
  cascade (0.3 s). In the upper third (subtitles take the bottom).
- Subtitles: on, big and bold, the word being spoken highlighted. Before generate_subtitles or add_voiceover, set
  edit_subtitles style: size 56–64 on 16:9 or 42–48 on 9:16 (3–4 words a line), bold true, highlight #FFD400,
  highlight_scale 1.1; on 9:16 also position bottom, margin 0.22 (above the platform's buttons).

## Sound

- Music: bright and light — find_audio "bright", "hopeful" or "electronic". The library has few upbeat tracks: if nothing
  fits, use no music and tell the user they can give you a track of their own.
- Voice: when someone talks on camera, use their voice. Only a video of product shots without speech gets a voiceover:
  add_voiceover with zh_female_lively or en_female_lively at speed 1.1, subtitles true.

## When the product is a course

- transcribe every lesson first, then pick three things: what learners can make by the end (a finished piece, a before/after,
  the most impressive step), the one or two strongest lines the teacher says ("By the end you can…"), and what the course
  covers (group the lessons into 3 modules).
- Structure: hook (the finished piece or the strongest line) → what the course teaches (3 modules, one picture + one line of
  text each) → who the teacher is (one sentence, optional) → call to action.
- Screen recordings must be readable: zoom into the part being worked on with edit_clip x / y / scale instead of shrinking the
  whole screen into 9:16.
- Footage with "WaterMark" in its name may be used unless the user says otherwise. No prices, no invented student counts or
  ratings.

## Sound effects

- Transition sounds come from add_clips sound_effect, made on this Mac (no download, no fal): a whoosh on a push, a pop on
  the first keyword of each selling point (not on every line), a shutter on a photo, one impact on the reveal. Give hit_at =
  the cut or the moment the word appears; SrtFlow places the start.

## Generated media (only if generate_media is among your tools)

- When find_audio has nothing bright, generate_media kind music ("upbeat, bright, electronic, no vocals") before asking the
  user for a track. Never generate pictures of the product.

## Taste

- The first frame is a poster: the product or the result big and sharp (filling 60–80% of the frame) with the line of big
  text, and something already moving within 0.3 s.
- Keyword text is the key 2–5 words, not the sentence being said, and it appears with the word as it is spoken (its time from
  transcribe or get_subtitles), at most 0.2 s before.
- Rhythm: two or three quick shots (0.8–1.5 s), then one held hero shot of the product (2–3 s, a slow push-in); vary the
  pattern, never the same three times.
- Punch in (shared taste rule 12) on the strongest selling line of someone talking.
- One accent colour, taken from the product or the brand, for the highlight and the keyword boxes; all other text white.
- The reveal gets the only whiteFade and the only impact; a rolling number lands with a ding or a hit.
- The call to action is calm: the product held still, the text rising or fading in, no sound effect.

## Avoid

- A pop animation and a pop sound on every line of text.
- Keyword text on every shot, or text that repeats the whole spoken sentence.
- Every shot 2 s long; pushes in several directions in one video.
- Music at full level under speech; a hard stop at the end.
- Made-up urgency: countdowns, prices or "only 3 left" that the user did not give.

## Checklist before export

- The first 3 s (look): big text and the subject are there.
- Something changes at least every 3 s.
- The voice is clear and the music does not cover it.
- The length is inside the range.
- The last frame has the call to action and holds for 1.5 s.
- Then "Look again before export" in the shared rules.
