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
   speech, music around −18 dB. Something is heard within the first 0.5 s; music fades out at the end (fade_out), never a hard stop.
6. Never invent numbers, reviews, student counts, prices or links; use only what the footage and the user give.
7. Before exporting, go through the recipe's checklist: look at the key moments of the timeline (the start, the first frame of
   each part, the end) and listen to the whole timeline.
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
12. Sound effects come from add_clips sound_effect, made on this Mac (whoosh, swoosh, suction, riser, downlifter, impact,
    boom, hit, pop, click, tick, ding, sparkle, beep, glitch, shutter): give hit_at = the timeline second the hit must
    land on (a cut, a word appearing) and SrtFlow sets the start. They sit at -8 dB under speech; change volume_db if
    needed. Use them before generate_media; find_audio is for music.
