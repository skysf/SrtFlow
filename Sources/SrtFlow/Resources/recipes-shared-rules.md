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
