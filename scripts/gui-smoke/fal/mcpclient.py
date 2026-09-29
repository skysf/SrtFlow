import json, os, queue, subprocess, threading, time

class MCP:
    """扮成 AI 客户端（老一代握手）：起 App 包里的 srtflow-mcp，按行收发 JSON-RPC。"""
    def __init__(self, helper, env=None):
        self.p = subprocess.Popen([helper], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, text=True, bufsize=1)
        self.next_id = 0
        self.waiting = {}
        self.notifications = []
        self.lock = threading.Lock()
        threading.Thread(target=self._read, daemon=True).start()
        threading.Thread(target=lambda: [None for _ in self.p.stderr], daemon=True).start()
        self.init = self.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "falsmoke", "version": "1"}})
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def _read(self):
        for line in self.p.stdout:
            try: msg = json.loads(line)
            except Exception: continue
            with self.lock:
                q = self.waiting.pop(msg["id"], None) if "id" in msg else None
                if q is None: self.notifications.append(msg)
            if q is not None: q.put(msg)

    def send(self, msg):
        self.p.stdin.write(json.dumps(msg) + "\n"); self.p.stdin.flush()

    def request(self, method, params=None, timeout=180):
        with self.lock:
            self.next_id += 1; rid = self.next_id
            q = queue.Queue(); self.waiting[rid] = q
        self.send({"jsonrpc": "2.0", "id": rid, "method": method, **({"params": params} if params is not None else {})})
        return q.get(timeout=timeout)

    def tools(self):
        return [t["name"] for t in self.request("tools/list")["result"]["tools"]]

    def call(self, name, args=None, timeout=180):
        reply = self.request("tools/call", {"name": name, "arguments": args or {}}, timeout=timeout)
        result = reply.get("result") or {}
        text = next((c["text"] for c in result.get("content", []) if c.get("type") == "text"), "")
        try: data = json.loads(text)
        except Exception: data = text
        return data, bool(result.get("isError"))

    def wait_job(self, job_id, seconds=120):
        end = time.time() + seconds
        while time.time() < end:
            data, _ = self.call("get_job", {"job_id": job_id, "wait_seconds": 10})
            if data.get("status") in ("done", "failed", "cancelled"): return data
        return data

    def close(self):
        try: self.p.stdin.close()
        except Exception: pass
        self.p.terminate()
