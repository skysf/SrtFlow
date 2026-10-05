---
id: documentary
title: Documentary
use_for: Travel, nature, culture, expeditions, interview stories, stories about people and companies.
---
# Documentary

- Shape: 16:9 for YouTube and Bilibili; 9:16 for a short-video version.
- Length: 1–3 minutes; 30–60 s for a short-video version.

## The bar

BBC natural-history films and National Geographic, with the restraint of PBS Frontline: the picture carries the story, the
narration adds what the picture cannot say, and the type has the calm of a museum label.

## Structure

1. The opening: the most powerful picture + one line of narration (or the original sound) that asks a question or sets the
   scene ("At the southern end of the Earth…").
2. The body: in order of time or place. Each part = one wide establishing shot + 2–3 medium or close details + one line of
   narration.
3. The high point: the most striking pictures; the music rises and the narration stops.
4. The end: back to a wide shot, one closing line, blackFade, then the credits.

## Pace and pictures

- Shots 3–6 s, the strongest images 6–8 s; let the pictures breathe. Let movements of animals and people finish.
- Transitions: hard cuts; crossFade (1 s) between parts; blackFade at the start and the end.
- Picture animation: no entrance animations. Photos, and now and then a still shot, slowly push in with set_keyframes
  (scale 1 → 1.05, the default easeInOut easing); everything else holds.
- Filter: realistic flatGrey or none; cold places mistBlue or coldWhite; warm light warmSun. Strength 0.3–0.5, gently.

## Text

- Place and time cards: "Antarctic Peninsula · January", bottom left, Avenir Next or PingFang SC regular 40–48, fade, 4 s.
- Title: Songti SC, Baskerville or Optima, centred, fade.
- Subtitles: on when there is narration or an interview; white with a light shadow (style shadow #00000099), at the bottom,
  no box, no word highlight (style highlight none).

## Sound

- Music: find_audio "documentary", "nature", "calm", "piano", "hopeful" or "emotional". 15–18 dB under the narration.
  In the gaps between narration lines, let the real sound (wind, animal calls) come through.
- Keep meaningful real sound: listen for the loud moments and look at what they are.
- Voice: add_voiceover with zh_male or en_male, or zh_female_warm / en_female_warm, at speed 0.95, subtitles true. Write short narration lines
  (Chinese ≤ 20 characters, English ≤ 15 words) with 1–2 s between them for the pictures. Put each line over the matching
  picture (say "penguins" while penguins are on screen).

## Sound effects

- A soft whoosh or downlifter on a chapter change comes from add_clips sound_effect (hit_at on the cut). Real-world
  ambience is not made this way.

## Generated media (only if generate_media is among your tools)

- Sound only: an ambience bed (wind, sea, a crowd) with kind sound_effect when the footage's own sound is unusable; kind
  music when the library has nothing that fits. Never generate pictures of a place or an animal — a documentary shows what
  was there.

## Taste

- Stillness is authority: no entrance animations and no decorative transitions; the movement comes from the footage itself.
- Hold the strongest images longer than feels comfortable; let a new scene's real sound play 1–2 s before narration starts
  over it.
- Picture first, then words: a narration line starts 0.5–1 s after the shot it is about, and says what the picture cannot.
- J-cuts between scenes: the next place's ambience or the music leads its picture by 0.5–1 s.
- Place and time cards always on the same margin (bottom left, x about 0.08), small and regular, fading in 0.6 s and out 0.4 s.
- Music enters after the opening line, not under its first word; it swells only at the high point while the narration stops,
  and ends on its own ending.

## Avoid

- Music wall to wall at one level.
- Impacts, risers and whooshes for drama: a documentary earns its emotion from real sound.
- Looks that change the place: neon, tealOrange, any filter at full strength.
- Narration that describes what is on screen ("Here we see penguins").

## Checklist before export

- Narration and pictures match.
- There is air between narration lines.
- The credits are at the end.
- Then "Look again before export" in the shared rules.
