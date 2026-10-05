---
id: cinematic-opening
title: Cinematic opening
use_for: The opening of a short film or travel film, a trailer feel, a portfolio or brand-story opening.
---
# Cinematic opening

- Shape: 16:9, with cinema letterbox bars: two black filled rectangles (set_shape kind rectangle, filled true, colour
  #000000, width 1, height 0.128, at y 0.064 and y 0.936), for the whole length. That makes a 2.39:1 picture.
- Length: 30–90 s.

## The bar

The opening of a festival short film or an A24 title sequence: quiet and sure of itself, every frame composed, the title
landing like a held breath let go. Fewer, longer, better shots.

## Structure

1. 0–5 s, cold open: sound first in the black (ambience, or the first note of the music) for 0.5–2 s, then the picture
   fades in from black (blackFade). The first shot is wide and shows where we are.
2. 5–25 s, the build: slow, long shots of 3–6 s, from far to near (wide → medium → close-up); the music slowly rises.
3. The title lands on the music's biggest accent after a breath (0.5–1 s of near-silence), centred, and stays 3–4 s.
4. 25–45 s, the lift: each shot a little shorter than the one before (e.g. 2.5, 2, 1.6, 1.2 s), cut on the beat
   (cut_to_beat; by hand when the beat is not clear); the feeling climbs.
5. The end: the last shot stays 1–2 s longer than feels necessary, then fades to black (blackFade 1–1.5 s) as the music ends.

## Pace and pictures

- Shots 3–6 s in the build, 1.5–2.5 s in the lift (shorter towards its end). Let actions finish; never cut in the middle of
  a movement.
- Transitions: hard cuts inside a part; crossFade (0.8–1.5 s) only where time passes; blackFade between parts. No pushes,
  wipes or white flashes.
- Picture animation: at most every second shot moves — a slow push-in (set_keyframes scale 1 → 1.04–1.06 over the whole
  shot, easeInOut) or a slow drift (position x moving 0.02–0.03). Shots with their own movement (a moving camera, someone
  walking) and the shot under the title hold still.
- Filter: blockbuster look tealOrange, nostalgic fadedFilm; strength 0.5–0.7 (the lower end when faces are on screen).

## Text

- Title: English Didot, Bodoni 72 or Optima in capitals with wide letter_spacing (20–40); Chinese Songti SC. font_size 90–120.
  An off-white such as #F2EEE6 looks calmer than pure white. animation_in focus (1–1.5 s), animation_out fade (0.6 s). Keep
  it off the letterbox bars.
- Place and year: small Avenir Next or PingFang SC regular, 36–44, bottom left inside the picture (x about 0.08), starting
  0.5 s after its shot; fade in 0.6 s, out 0.4 s, 4 s on screen.
- No other text.
- Subtitles: off unless there is dialogue; then small white text without a box (style size 44–48, highlight none).

## Sound

- Music: epic and emotional — find_audio "epic", "trailer", "opening", "orchestral" or "emotional". Slide it so its biggest
  accent lands on the title (move the clip or its source_in), dip it 8–12 dB with volume_curve for the 0.5–1 s before the
  title, and end the video on the music's own ending (shared taste rule 20); fade it out over 2–3 s only when the ending
  cannot be used.
- Voice: usually none. For a narration, add_voiceover with zh_male or en_male at speed 0.9, short sentences with
  1–2 s between them.

## Sound effects

- Under the moment the title lands: add_clips sound_effect riser, then impact (or boom), both with hit_at = that second
  (the riser builds into it, the impact lands on it). Nothing else; made on this Mac, no fal needed.

## Generated media (only if generate_media is among your tools)

- A missing wide establishing shot: generate_media kind text_to_video, or kind image_to_video from a photo the user gave;
  draft at 480p first.
- Music when the library has nothing big enough: kind music ("orchestral, rising, cinematic, no vocals").
- Generated video has its own sound: keep it under the music.

## Taste

- Restraint is the style: one title, one place card, one kind of motion at a time; let silence and stillness do the work.
- Contrast carries the feeling: long quiet holds before the title, quickening cuts after it, and the end slows down again.
- Compose like a still photograph: the horizon on a third, the subject off-centre, room in the direction it looks or moves.
- The title is the peak: nothing else moves or makes a sound while it lands.

## Avoid

- A slow push-in on every shot (an earlier version of this style asked for it; it is the most common AI tell).
- A title on a random moment of the music; a riser with no hit after it.
- Any text besides the title and one place card; boxes behind text.
- Fast cuts in the first 15 s; transitions other than crossFade and blackFade.

## Checklist before export

- The letterbox bars are the same height top and bottom, and no text sits on them.
- look at the moment the title appears: it is the best-composed frame of the video.
- There is a breath of near-silence before the title.
- The music ends with the picture (its own ending, or a 2–3 s fade).
- It opens with sound in the black, then fades in.
- Then "Look again before export" in the shared rules.
