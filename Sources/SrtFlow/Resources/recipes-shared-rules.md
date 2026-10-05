## Rules for every recipe

1. Know the footage before cutting: open_folder, then look files (all short files at once) or look shots=true (long videos),
   transcribe anything with speech, listen for levels and silences. Choose shots by what they show, not by file names.
2. Ask once which platform the video is for if the user has not said: TikTok, Douyin, Xiaohongshu, Reels or Shorts → 9:16;
   YouTube or Bilibili → 16:9.
3. 9:16 safe area: the platform's buttons and captions cover the top 10%, bottom 20% and right 12% of the frame. Keep big
   text, subtitles and anything that must be read outside them (text y between 0.12 and 0.75, x between 0.08 and 0.85).
4. Text: one main point per screen; at most two fonts in a video; short lines (Chinese ≤ 8 characters, English ≤ 5 words);
   never over faces or the main subject (compare set_text's block with look).
5. Sound: with speech, keep music about 15 dB under the voice (measure with listen, set with edit_clip volume_db); without
   speech, music around −18 dB. Something is heard within the first 0.5 s. At the end the music finishes on its own ending
   (taste rule 20 below) or fades out (fade_out) — never a hard stop.
6. Never invent numbers, reviews, student counts, prices or links; use only what the footage and the user give.
7. Before exporting, go through the recipe's checklist: look at the key moments of the timeline (the start, the first frame of
   each part, the end) and listen to the whole timeline. Then do "Look again before export" below.
8. When done, tell the user which recipe you followed, the length, the shape and where the video is; with library music, give
   the credit lines (music_credits).
9. Subtitles: set how they look with edit_subtitles style before generate_subtitles or add_voiceover subtitles=true (lines are
   cut to fit that size). It changes only this project, never the user's Burn In Subtitles page. Word highlight only lights
   lines SrtFlow made from speech or a voiceover (get_subtitles tells lines_with_word_times).
10. Sizes count against the frame's height: set_text font_size and the subtitle style size are pixels on a frame 1080
    high, and a 9:16 frame is 1920 high, so the same number draws 1.78× larger across its width. A recipe names the shape
    its sizes are for; a single number is for 16:9 — on 9:16 divide it by 1.8.
11. If generate_media is among your tools (the user connected fal.ai; otherwise skip this rule): use it only for what
    the footage cannot give — a missing establishing shot, a real-world sound (ambience, a crowd, an animal), music when
    find_audio has nothing that fits — never to replace footage the user has. Tell the user the estimate
    (estimated_cost_usd in the result) before making anything, especially video. When the result or get_job says
    waiting_for_user, SrtFlow is asking the user at the top of its window: tell them to answer there and keep waiting.
    Generated video comes with its own sound: mute it or turn it down under music and voice (edit_clip volume_db or
    muted). Make video drafts at resolution 480p and remake only the shots you keep at 1080p. The terms of use for
    generated content are the provider's, not SrtFlow's; music_credits covers only library music. Never present
    generated pictures as the user's own footage.
12. Sound effects, in this order: first find_audio kind=sound_effect for a recorded or produced one (whooshes, impacts,
    risers, wind, ice, water, mechanical…; place it with add_clips library_id and hit_at); when nothing fits, add_clips
    sound_effect makes one on this Mac (whoosh, swoosh, suction, riser, downlifter, impact, boom, hit, pop, click, tick,
    ding, sparkle, beep, glitch, shutter): give hit_at = the timeline second the hit must land on (a cut, a word
    appearing) and SrtFlow sets the start. Both sit at -8 dB under speech; change volume_db if needed. generate_media is
    only for real-world sounds neither has; find_audio is also where music comes from.

## Plan before you cut

Before the first edit, write a beat sheet and show it to the user in a few lines, then carry on (they can stop you or undo
the round; wait for an OK only when they asked to see plans first):

- One sentence: "This video tells <who> that <what>."
- One row per beat: its seconds; its job (hook, build, peak, rest, end); the shot (file and time); what moves and how, as a
  verb (slams in, drifts, holds still, draws itself, counts up); how it hands over to the next beat (a hard cut, or which
  transition and why); and its sound (a music hit, an effect, a pause, a line of speech).
- Name the rhythm before cutting, e.g. "fast-fast-HOLD-fast-PEAK-rest-end": where is the peak, where does the video breathe?
- A beat you cannot give a job to is cut.

## Taste for every style

What separates an edited video from an assembled one. When a style's own Taste section says otherwise, the style wins.

Pace
1. Vary shot lengths on purpose: the longest shot is at least 3× the shortest, and the same length (within 0.2 s) never
   comes three times in a row. A held shot after a run of quick ones hits harder than more speed.
2. Each part builds, breathes and resolves: it starts with energy, holds one calm moment, and ends decisively.
3. Cut on something: the end of a movement, a look or a gesture, a word. Cut on the beat where the music drives (the build
   and the peak; cut_to_beat does it) and where the picture asks elsewhere — a video cut on every beat feels mechanical.
4. Let moments land: keep 0.5–1 s after an action finishes or a line is said before cutting away.
5. Change the shot size or the angle at every cut (a wide shot, then a close one; not two wide shots of the same thing). A
   jump cut is fine only when it is meant (talking heads, vlog energy).

Picking shots
6. Use the best 20–30% of the footage: sharp, well lit, a clear subject, faces with expression. Drop soft, shaky or dull
   shots even when they are on topic; a shorter video of strong shots beats a longer one.
7. Open on the strongest picture you have, not the first one filmed.

Transitions
8. A transition says something. A hard cut is the default and the strongest; crossFade = time passes or a feeling goes on;
   blackFade = a chapter ends, the video starts or ends; whiteFade = a flash for a reveal; pushes and wipes = energy, in
   promos and vlogs. Besides hard cuts use at most two kinds in one video, and at most one decorative transition in any 10 s.

Motion
9. Not every shot moves. Mix still shots, slow push-ins (set_keyframes scale 1 → 1.04–1.08 over the shot), slow drifts
   (position x or y moving 0.02–0.04 over the shot) and the footage's own movement. Never the same move on two shots in a
   row and never a move on every shot: a still shot after moving ones is a breath.
10. Easing carries the feeling: easeInOut for camera-like moves (a push, a drift), easeOut for things that arrive and
    settle, easeIn for things that leave, linear only for a very slow drift through a whole shot; snap for a fast push-in or
    a crash zoom (0.2–0.3 s), overshoot for a picture that pops into place (a picture-in-picture arriving), spring for
    something playful. Never overshoot or spring on a slow camera move, and at most one of them in any 10 s.
11. Asymmetry and offsets: entrances take longer than exits (text animation_in_duration 0.5–0.8 s, animation_out_duration
    0.3–0.4 s). A text starts 0.2–0.3 s after the cut under it, not on the cut. Texts of one group arrive one after another,
    0.1–0.2 s apart and the whole group within 0.5 s, the most important one first.
12. Punch in on emphasis in talking-head footage: split_clip where the key line starts and make the second piece 1.12–1.2×
    bigger, framing the face (edit_clip scale; or set_keyframes scale with the same value at the start and the end when the
    clip has keyframes); go back to the wider framing at the next idea. One camera then feels like two. At most one punch-in
    every 8–10 s. A move instead of a cut: set_keyframes scale 1 → 1.15 over 0.2–0.3 s with easing snap.

Text
13. One accent colour for the whole video, taken from the footage or the brand; all other text white or near-black.
    Emphasise with weight, size or that colour — one of them at a time — and never with italics.
14. Hierarchy: one big thing per screen; a title is 2–3× the size of a label; at most two fonts and two weights.
15. Big bold sans-serif headlines read best with letter_spacing 0 or slightly negative (down to −2); small labels and
    elegant capitals with wide letter_spacing (10–40).
16. Place text on purpose: on a third or along an edge of the picture, with the same margin every time (at least 6% of the
    frame); centred only for titles and solemn moments.

Sound
17. Sound starts the video: the first sound comes with or before the first picture.
18. The music's strongest moment is the video's peak: slide the music (its start, or source_in) so its hit or drop lands on
    the peak, rather than cutting the pictures to wherever the music happens to peak.
19. A breath before the peak: 0.3–1 s of near-silence just before the biggest moment (dip the music with volume_curve, no
    effects), then the hit.
20. End on the music's own ending: place the track so its last note ends with the video. If it is too long, keep its start
    and its real ending and take out a middle part: split_clip at two downbeats (listen beats=true gives them) a whole
    number of bars apart (4, 8 or 16), delete the middle with delete_items, move the ending to a new_audio track so it
    starts where the first part stops, and give the first part fade_out 0.1 and the ending fade_in 0.1. Fade out in the
    middle of a phrase only when nothing else works.
21. J-cuts and L-cuts: let the next scene's sound (ambience, music, a voiceover line) start 0.3–1 s before its picture, or
    let a voice carry on over the next picture. It hides cuts and pulls the viewer on. (A video clip's own sound stays with
    its picture; this works with the clips on audio tracks.)
22. Sound effects punctuate, they do not decorate: at most one every 2–3 s, the biggest on the peak, none in quiet moments.

## AI tells to avoid

These make a video look generated; check the timeline for each before export:
- every shot the same length, or every cut on a beat;
- a crossFade (or any decorative transition) between every two shots;
- a slow push-in on every shot;
- every text centred, starting exactly on the cut, all with the same animation;
- a sound effect on every cut and every word;
- music starting at full volume at 0 s and fading out in the middle of a phrase;
- text over faces, a box behind every text, more than one accent colour;
- a filter at full strength, or a different filter for each part;
- opening on a logo, a slow fade-in or the least interesting shot;
- the same choices in every video, whatever the footage.

## Look again before export

After the style's checklist, judge the video as a viewer — with look and listen, not from memory. Fix what fails, then tell
the user in one line what you checked.
1. Poster: look at the peak moment alone (size large). Would it work as a still? If not, change the shot, the framing or the
   text.
2. At a glance: look at 4–6 key moments together (size small). Is it clear in each what matters most?
3. Rhythm: list the shot lengths from get_timeline. Do they follow the beat sheet (quick in the build, held at the rests)? If
   most are within 0.3 s of each other, recut.
4. Rests or gaps: find the stretches with no new shot, text or sound event. Are they rests you planned, or gaps where the
   video just stops?
5. Sound: listen around the peak and the end. Is there a breath before the peak, and does the music end with the picture?

## Learning a style from a reference video

When the user gives you a reference video (a trailer, an ad, a scene from a film they like) and wants its style:
- Measure it with SrtFlow's tools: look shots=true (where it cuts, how long each shot is), listen beats=true (tempo, where the
  music hits and drops, the silences), text_scan=true (title cards — ignore burned-in subtitles unless the user asks about
  them) and look at a few frames (framing, colour, type, how text sits).
- Write what you measured as a style with save_recipe, in the same sections as these styles: the bar, structure by the
  second, pace (the median and range of shot lengths in each part), transitions and how often, motion, text, sound, taste,
  avoid and a checklist. Numbers, not adjectives.
- Learn the grammar, not the content: never reuse its footage, music, logos or title designs.
- Never download a reference from the web; ask the user for the file.
