---
id: cinematic-opening
title: Cinematic opening
use_for: The opening of a short film or travel film, a trailer feel, a portfolio or brand-story opening.
---
# Cinematic opening

- Shape: 16:9, with cinema letterbox bars: two black filled rectangles (set_shape kind rectangle, filled true, colour
  #000000, width 1, height 0.128, at y 0.064 and y 0.936), for the whole length. That makes a 2.39:1 picture.
- Length: 30–90 s.

## Structure

1. 0–5 s, cold open: sound first in the black (ambience, or the first note of the music), then the picture fades in from
   black (blackFade). The first shot is wide and shows where we are.
2. 5–25 s, the build: slow, long shots of 3–6 s, from far to near (wide → medium → close-up); the music slowly rises.
3. The title lands on a strong beat or accent of the music, centred, and stays 3–4 s.
4. 25–45 s, the lift: shorter shots (1.5–2.5 s), cut on the beat (cut_to_beat; cut by hand when the beat is not clear);
   the feeling climbs.
5. The end: the last shot stays a little longer, then fades to black (blackFade).

## Pace and pictures

- Shots 3–6 s in the build, 1.5–2.5 s in the lift. Let actions finish; never cut in the middle of a movement.
- Transitions: crossFade (0.8–1.5 s) and blackFade between parts. No pushes or wipes.
- Picture animation: still or steady shots slowly push in with set_keyframes (scale 1 → 1.06–1.1 over the whole shot).
- Filter: blockbuster look tealOrange, nostalgic fadedFilm; strength 0.6–0.8.

## Text

- Title: English Didot, Bodoni 72 or Optima in capitals with wide letter_spacing (20–40); Chinese Songti SC. font_size 90–120.
  animation_in focus (1–1.5 s), animation_out fade. Keep it off the letterbox bars.
- Place and year: small Avenir Next or PingFang SC regular, 36–44, bottom left inside the picture, fade, 4 s.
- No other text.
- Subtitles: off unless there is dialogue; then small white text without a box (style size 44–48, highlight none).

## Sound

- Music: epic and emotional — find_audio "epic", "trailer", "opening", "orchestral" or "emotional". It starts with the video,
  the title sits on a strong beat, and it fades out over 2–3 s at the end.
- Voice: usually none. For a narration, add_voiceover with zh_male or en_male at speed 0.9, short sentences with
  1–2 s between them.

## Checklist before export

- The letterbox bars are the same height top and bottom, and no text sits on them.
- look at the moment the title appears.
- The music fades out at the end.
- It opens by fading in from black.
