#!/usr/bin/env python3
"""假 fal：照 fal 队列接口的样子回话，记下每个请求，给冒烟用。
用法：fakefal.py <端口> <资源目录> <期望的 Key>
端点决定行为：unknown（acme/…）永远 IN_PROGRESS（测取消）；别的排队两次、做两次、完成。
GET /__log 回记录（JSON）；POST /__reset 清记录。"""
import json, os, re, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT, ASSETS, KEY = int(sys.argv[1]), sys.argv[2], sys.argv[3]
LOCK = threading.Lock()
LOG, JOBS = [], {}
COUNTER = [0]

def outputs(endpoint, body):
    base = f"http://127.0.0.1:{PORT}/files/"
    if endpoint.startswith("bytedance/seedream"):
        return {"images": [{"url": base + "pic.png", "content_type": "image/png", "file_name": "pic.png", "width": 1536, "height": 864}]}
    if endpoint.startswith("minimax/h3-max"):
        return {"video": {"url": base + "clip.mp4", "content_type": "video/mp4", "file_name": "clip.mp4"}, "expanded_prompt": body.get("prompt")}
    if endpoint.startswith("elevenlabs/tts"):
        words = (body.get("text") or "").split()
        step = 3.6 / max(len(words), 1)
        stamps = [{"word": w, "start": round(0.2 + i * step, 3), "end": round(0.2 + (i + 1) * step - 0.05, 3)} for i, w in enumerate(words)]
        out = {"audio": {"url": base + "say.mp3", "content_type": "audio/mpeg"}}
        if body.get("timestamps"): out["timestamps"] = stamps
        return out
    if endpoint.startswith("elevenlabs/music"):
        return {"audio": {"url": base + "song.mp3", "content_type": "audio/mpeg"}}
    if endpoint.startswith("sonilo"):
        return {"audio": {"url": base + "door.wav", "content_type": "audio/wav"}, "audios": [{"url": base + "door.wav"}]}
    if endpoint.startswith("fal-ai/zonos2"):
        return {"audio": {"url": base + "say.mp3", "content_type": "audio/mpeg"}, "seed": 1}
    return None

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def send_json(self, status, obj):
        data = json.dumps(obj).encode()
        self.send_response(status); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)

    def record(self, body=None):
        entry = {"method": self.command, "path": self.path, "auth": self.headers.get("Authorization"), "body": body}
        with LOCK: LOG.append(entry)
        return entry

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b""
        try: return json.loads(raw) if raw else None
        except Exception: return {"_raw": len(raw)}

    def do_GET(self):
        if self.path == "/__log":
            with LOCK: return self.send_json(200, LOG)
        if self.path.startswith("/files/"):
            self.record()
            p = os.path.join(ASSETS, os.path.basename(self.path))
            if not os.path.exists(p): return self.send_json(404, {})
            data = open(p, "rb").read()
            self.send_response(200); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data); return
        self.record()
        if self.headers.get("Authorization") != f"Key {KEY}": return self.send_json(401, {"detail": "Unauthorized"})
        m = re.match(r"^/(.+)/requests/([^/]+)(/status)?$", self.path)
        if not m: return self.send_json(404, {"detail": "nope"})
        endpoint, rid, status = m.group(1), m.group(2), m.group(3)
        with LOCK: job = JOBS.get(rid)
        if not job: return self.send_json(404, {"detail": "unknown request"})
        if job["cancelled"]: return self.send_json(200, {"status": "COMPLETED", "error": "cancelled"}) if status else self.send_json(422, {"detail": "cancelled"})
        if status:
            job["polls"] += 1
            if job["outputs"] is None: return self.send_json(200, {"status": "IN_PROGRESS"})
            if job["polls"] <= 2: return self.send_json(200, {"status": "IN_QUEUE", "queue_position": 3 - job["polls"]})
            if job["polls"] <= 4: return self.send_json(200, {"status": "IN_PROGRESS"})
            return self.send_json(200, {"status": "COMPLETED"})
        return self.send_json(200, job["outputs"])

    def do_POST(self):
        body = self.body()
        self.record(body)
        if self.path == "/__reset":
            with LOCK: LOG.clear()
            return self.send_json(200, {})
        if self.headers.get("Authorization") != f"Key {KEY}": return self.send_json(401, {"detail": "Unauthorized"})
        endpoint = self.path.lstrip("/")
        with LOCK:
            COUNTER[0] += 1; rid = f"req-{COUNTER[0]}"
            JOBS[rid] = {"endpoint": endpoint, "body": body, "polls": 0, "cancelled": False, "outputs": outputs(endpoint, body or {})}
        base = f"http://127.0.0.1:{PORT}/{endpoint}/requests/{rid}"
        self.send_json(200, {"request_id": rid, "status_url": base + "/status", "response_url": base, "cancel_url": base + "/cancel", "queue_position": 0})

    def do_PUT(self):
        self.record()
        m = re.match(r"^/(.+)/requests/([^/]+)/cancel$", self.path)
        if m:
            with LOCK:
                if m.group(2) in JOBS: JOBS[m.group(2)]["cancelled"] = True
            return self.send_json(202, {"status": "CANCELLATION_REQUESTED"})
        self.send_json(404, {})

ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
