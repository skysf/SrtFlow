"""冒烟场景一：generate_media 五种、放上时间线、配旁白的 fal 档（词时间 → 字幕）、克隆、账、Key 头。
要先 `scripts/gui-smoke/fal/run.sh`（起假 fal 和测试 App）。见 docs/testing/gui-smoke-testing.md 四之八。"""
import json, os, sys, time, urllib.request
sys.dont_write_bytecode = True   # 别在仓库里留 __pycache__
sys.path.insert(0, os.path.dirname(__file__))
from mcpclient import MCP

D = os.environ.get("FALSMOKE_DIR", os.path.join(os.environ.get("TMPDIR", "/tmp"), "srtflow-fal-smoke"))
APP = D + "/SrtFlowFalSmoke.app"
KEY = "smoke-id-1234-abcd:smoke-secret-0123456789abcdef"
fails = 0
def ok(cond, msg, extra=""):
    global fails
    print(("PASS " if cond else "FAIL ") + msg + (("  -> " + str(extra)[:300]) if (extra and not cond) else ""))
    if not cond: fails += 1
def server_log():
    return json.load(urllib.request.urlopen("http://127.0.0.1:18765/__log"))
def posts(endpoint_prefix):
    return [e for e in server_log() if e["method"] == "POST" and e["path"].lstrip("/").startswith(endpoint_prefix)]

mcp = MCP(APP + "/Contents/Helpers/srtflow-mcp")
tools = mcp.tools()
ok("generate_media" in tools, "tools/list has generate_media (key seeded, marker written at launch)")
ok("generate_media" in mcp.init["result"]["instructions"], "instructions mention generate_media")
ok(mcp.init["result"]["capabilities"]["tools"]["listChanged"] is True, "handshake: listChanged")
mcp.call("set_view", {"mode": "background"})
work = D + "/work"
opened, err = mcp.call("open_folder", {"path": work})
ok(not err, "open_folder on the scratch folder", opened)

status, _ = mcp.call("get_status")
gen = status.get("generation") or {}
ok(gen.get("provider") == "fal.ai" and gen.get("daily_limit_usd") == 10 and gen.get("spent_today_usd") == 0, "get_status.generation: provider, limit 10, spent 0", gen)
ok(gen.get("models", {}).get("text_to_video") == "minimax/h3-max/text-to-video" and gen.get("models", {}).get("music") == "elevenlabs/music/v2.5", "get_status.generation.models has the presets", gen.get("models"))

def make(args):
    started, err = mcp.call("generate_media", args)
    return started, err

# ---- 图
started, err = make({"kind": "image", "prompt": "a lighthouse at dusk, oil painting", "name": "lighthouse"})
ok(not err and started.get("status") == "started" and started.get("estimated_cost_usd") == 0.027, "image: started, estimated $0.027", started)
job = mcp.wait_job(started["job_id"], 60)
ok(job.get("status") == "done", "image: job done", job)
file = job.get("file", "")
ok(file.endswith(".png") and os.path.exists(os.path.join(work, file) if not file.startswith("/") else file), "image: the png is on disk (in the opened folder's SrtFlow folder)", file)
ok("SrtFlow" in file, "image: file path is under SrtFlow/<generated>", file)
p = posts("bytedance/seedream")
ok(len(p) == 1 and p[0]["auth"] == "Key " + KEY, "image: one POST to the seedream endpoint with the Key header")
ok(p and p[0]["body"].get("image_size") == "landscape_16_9" and p[0]["body"].get("output_format") == "png" and p[0]["body"].get("num_images") == 1, "image: default shape follows the 1920x1080 canvas", p[0]["body"] if p else None)
status, _ = mcp.call("get_status")
ok(abs(status["generation"]["spent_today_usd"] - 0.027) < 1e-6, "ledger: spent today is $0.027 after one image", status.get("generation"))

# ---- 文生视频 + 放上时间线
started, err = make({"kind": "text_to_video", "prompt": "a fox runs through snow", "resolution": "480p", "duration": 5, "aspect_ratio": "9:16", "name": "fox"})
ok(not err and abs(started.get("estimated_cost_usd", 0) - 0.25) < 1e-9, "text_to_video 480p 5 s: estimated $0.25", started)
job = mcp.wait_job(started["job_id"], 90)
ok(job.get("status") == "done" and job.get("file", "").endswith(".mp4"), "text_to_video: job done with an mp4", job)
b = posts("minimax/h3-max/text-to-video")
ok(len(b) == 1 and b[0]["body"] == {"prompt": "a fox runs through snow", "prompt_expansion_mode": "balanced", "duration": 5, "resolution": "480P", "aspect_ratio": "9:16"}, "text_to_video: the request body", b[0]["body"] if b else None)
added, err = mcp.call("add_clips", {"clips": [{"file": job["file"]}]})
ok(not err and added.get("added"), "add_clips puts the generated video on the timeline", added)
timeline, _ = mcp.call("get_timeline")
tracks = json.dumps(timeline)
ok('"V1"' in tracks and "fox.mp4" in tracks, "the generated video is on V1 (its own sound plays with the clip; no separate audio track)", tracks[:300])

# ---- 图生视频（本地图编成 data URI、不发画幅）
started, err = make({"kind": "image_to_video", "prompt": "the camera pushes in", "image": "pic.png", "aspect_ratio": "9:16"})
ok(not err and abs(started.get("estimated_cost_usd", 0) - 0.40) < 1e-9, "image_to_video 768p 5 s: estimated $0.40", started)
ok(any("aspect_ratio was ignored" in n for n in started.get("notes", [])), "image_to_video: aspect_ratio is reported as ignored", started.get("notes"))
job = mcp.wait_job(started["job_id"], 90)
ok(job.get("status") == "done", "image_to_video: job done", job)
b = posts("minimax/h3-max/image-to-video")
ok(len(b) == 1 and b[0]["body"]["image_url"].startswith("data:image/png;base64,") and "aspect_ratio" not in b[0]["body"], "image_to_video: picture goes in as a data URI, no aspect_ratio", list(b[0]["body"].keys()) if b else None)

# ---- 音乐、音效
started, err = make({"kind": "music", "prompt": "warm lo-fi beat", "duration": 30, "name": "lofi"})
ok(not err and started.get("estimated_cost_usd") == 0.6, "music 30 s: estimated $0.60 (a started minute)", started)
job = mcp.wait_job(started["job_id"], 60)
ok(job.get("status") == "done" and job.get("file", "").endswith(".mp3"), "music: done with an mp3", job)
b = posts("elevenlabs/music")
ok(len(b) == 1 and b[0]["body"] == {"prompt": "warm lo-fi beat", "music_length_ms": 30000, "force_instrumental": True}, "music: the request body", b[0]["body"] if b else None)
added, err = mcp.call("add_clips", {"clips": [{"file": job["file"], "track": "new_audio"}]})
ok(not err and added.get("added"), "add_clips puts the generated music on a new audio track", added)
started, err = make({"kind": "sound_effect", "prompt": "a wooden door creaks open"})
job = mcp.wait_job(started["job_id"], 60)
ok(job.get("status") == "done" and job.get("file", "").endswith(".wav"), "sound effect: done with a wav", job)
b = posts("sonilo")
ok(len(b) == 1 and b[0]["body"] == {"prompt": "a wooden door creaks open", "duration": 5, "audio_format": "wav"}, "sound effect: the request body", b[0]["body"] if b else None)

# ---- 参数错误回给 AI 的话
for args, needle in [({"kind": "image_to_video", "prompt": "x"}, "image is required"), ({"kind": "music", "prompt": "x", "image": "pic.png"}, "only used by image_to_video"),
                     ({"kind": "image", "prompt": "x", "model": "not a model"}, "endpoint id"), ({"kind": "text_to_video", "prompt": "x", "resolution": "720p"}, "resolution"),
                     ({"kind": "video", "prompt": "x"}, "kind"), ({"kind": "image", "prompt": "x", "options": "nope"}, "options")]:
    data, err = mcp.call("generate_media", args)
    ok(err and needle in json.dumps(data), f"bad arguments {list(args.keys())}: an error that says '{needle}'", data)

# ---- 配旁白：fal 那一档
lines = [{"text": "Welcome to the show. Today we look at the sea."}, {"text": "It is bigger than you think."}]
voice, err = mcp.call("add_voiceover", {"lines": lines, "subtitles": True})
ok(not err and voice.get("voice", {}).get("name") == "Rachel" and voice["voice"].get("quality") == "fal.ai voice", "add_voiceover uses the fal.ai voice (warm English role → Rachel)", voice)
ok((voice.get("subtitles") or {}).get("added", 0) >= 2, "add_voiceover: subtitles from fal's word times", voice.get("subtitles"))
b = posts("elevenlabs/tts")
ok(len(b) == 2 and b[0]["body"].get("timestamps") is True and b[0]["body"].get("voice") == "Rachel" and b[0]["body"].get("language_code") == "en", "add_voiceover: the request body asks for word times", b[0]["body"] if b else None)
voice2, err = mcp.call("add_voiceover", {"lines": [{"text": "Thanks for watching."}], "voice": "en_male"})
ok(not err and voice2.get("voice", {}).get("name") == "Brian", "a role maps to its fal.ai voice", voice2)
# 克隆
clone, err = mcp.call("add_voiceover", {"lines": [{"text": "Cloned line."}], "clone_from": "voice-sample.mp3", "clone_seconds": 5})
ok(not err and clone.get("voice", {}).get("quality") == "fal.ai voice", "clone_from: spoken through the clone model", clone)
b = posts("fal-ai/zonos2")
ok(len(b) == 1 and b[0]["body"].get("reference_audio_url", "").startswith("data:audio/wav;base64,UklGR") and b[0]["body"].get("text") == "Cloned line.", "clone: the sample goes in as a WAV data URI", list(b[0]["body"].keys()) if b else None)
bad, err = mcp.call("add_voiceover", {"lines": [{"text": "x"}], "clone_from": "nope.mp3"})
ok(err and "no file" in json.dumps(bad).lower(), "clone_from: a missing file is reported", bad)

# ---- 账、Key 头
status, _ = mcp.call("get_status")
spent = status["generation"]["spent_today_usd"]
expected = 0.027 + 0.25 + 0.40 + 0.6 + 0.009 + (len(lines[0]["text"]) + len(lines[1]["text"])) * 0.08 / 1000 + len("Thanks for watching.") * 0.08 / 1000 + len("Cloned line.") / 4 / 60 * 0.01 * 0 
ok(spent >= 1.28 and spent < 1.35, f"ledger: spent today adds up ({spent})", status["generation"])
log = server_log()
ok(all(e["auth"] == "Key " + KEY for e in log if e["method"] in ("POST", "PUT") or "/requests/" in e["path"]), "every fal API call carries the Key header")
ok(all(e["auth"] is None for e in log if e["path"].startswith("/files/")), "the Key is never sent to the file host")
print(f"\n{'ALL PASSED' if fails == 0 else str(fails) + ' FAILED'}")
mcp.close()
sys.exit(1 if fails else 0)
