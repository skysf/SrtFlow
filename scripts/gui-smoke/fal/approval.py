"""冒烟场景二：花钱的把关 —— 超额度 / 价格不明先在提示条上问、cancel_job 收回问题、「允许」才提交、「先不要」不花钱、停止。
按钮靠辅助功能点（ax.sh，按 accessibilityIdentifier）。**问的时候测试 App 会跳到最前面**（`bringSrtFlowForward`），人在用机器时先说一声。
要先 `scripts/gui-smoke/fal/run.sh 0.30`（每日上限 0.30）。见 docs/testing/gui-smoke-testing.md 四之八。"""
import json, os, subprocess, sys, time, urllib.request
sys.dont_write_bytecode = True   # 别在仓库里留 __pycache__
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcpclient import MCP
HERE = os.path.dirname(os.path.abspath(__file__))
D = os.environ.get("FALSMOKE_DIR", os.path.join(os.environ.get("TMPDIR", "/tmp"), "srtflow-fal-smoke"))
APP = D + "/SrtFlowFalSmoke.app"
fails = 0
def ok(cond, msg, extra=""):
    global fails
    print(("PASS " if cond else "FAIL ") + msg + (("  -> " + str(extra)[:400]) if (extra and not cond) else ""))
    if not cond: fails += 1
def server_log(): return json.load(urllib.request.urlopen("http://127.0.0.1:18765/__log"))
def posts(prefix): return [e for e in server_log() if e["method"] == "POST" and e["path"].lstrip("/").startswith(prefix)]
def ax(*a): return subprocess.run([HERE + "/ax.sh", *a], capture_output=True, text=True).stdout.strip()
def wait_for(cond, seconds=20):
    end = time.time() + seconds
    while time.time() < end:
        v = cond()
        if v: return v
        time.sleep(0.5)
    return cond()
def waiting_job(job_id):
    def f():
        d, _ = mcp.call("get_job", {"job_id": job_id})
        return d if d.get("waiting_for_user") or d.get("status") != "running" else None
    return wait_for(f, 30)

mcp = MCP(APP + "/Contents/Helpers/srtflow-mcp")
windows = subprocess.run(["osascript", "-e", 'tell application "System Events" to tell process "SrtFlowFalSmoke" to get count of windows'],
                         capture_output=True, text=True).stdout.strip()
if windows in ("", "0"):
    # 下面读提示条、点按钮的步骤都要靠它：读不到窗口就会红（不许跳过当通过），原因见 gui-smoke-testing.md 四之八第 5 条。
    print("NOTE System Events cannot see the smoke app's windows (count of windows = %r): the bar / button checks below will fail" % windows)
mcp.call("set_view", {"mode": "background"})
mcp.call("open_folder", {"path": D + "/work"})
status, _ = mcp.call("get_status")
ok(status["generation"]["daily_limit_usd"] == 0.3, "the daily limit from settings is $0.30", status.get("generation"))

# 1. 超额度：先问，不提交
started, err = mcp.call("generate_media", {"kind": "text_to_video", "prompt": "a fox", "name": "ask-video"})
ok(not err and abs(started["estimated_cost_usd"] - 0.40) < 1e-9, "video 768p: estimated $0.40 (over the $0.30 limit)", started)
job = waiting_job(started["job_id"])
ok(job and job.get("status") == "running" and "approve" in job.get("waiting_for_user", ""), "the job is running with waiting_for_user (the AI is told to relay the question)", job)
ok(len(posts("minimax/h3-max/text-to-video")) == 0, "nothing was sent to fal before the user answers")
time.sleep(1)
texts = ax("texts")
ok("estimated cost $0.40" in texts and "$0.30 daily limit" in texts, "the top bar shows the question with the numbers", texts[:600])
ok(ax("click", "ai-banner-none") == "no button ai-banner-none", "(ax helper sanity: an unknown identifier finds nothing)")
# 2. AI 取消（cancel_job）：问题收回、没花钱
cancelled, _ = mcp.call("cancel_job", {"job_id": started["job_id"]})
job = mcp.wait_job(started["job_id"], 20)
ok(job.get("status") == "cancelled", "cancel_job: the job is cancelled", job)
time.sleep(1)
ok("estimated cost $0.40" not in ax("texts"), "cancel_job withdraws the question from the bar")
status, _ = mcp.call("get_status")
ok(status["generation"]["spent_today_usd"] == 0, "nothing was recorded for a question nobody answered", status.get("generation"))

# 3. 额度内不问
started, err = mcp.call("generate_media", {"kind": "image", "prompt": "a lighthouse", "name": "within-limit"})
job = mcp.wait_job(started["job_id"], 60)
ok(job.get("status") == "done" and "waiting_for_user" not in job, "an image inside the limit is made without asking", job)
status, _ = mcp.call("get_status")
ok(abs(status["generation"]["spent_today_usd"] - 0.027) < 1e-6, "ledger: $0.027", status.get("generation"))

# 4. 没登记单价的模型：每次问
before = len(posts("acme/whatever"))
started, err = mcp.call("generate_media", {"kind": "image", "prompt": "x", "model": "acme/whatever"})
ok(not err and started.get("price_known") is False and "estimated_cost_usd" not in started, "an unregistered endpoint has no estimate", started)
job = waiting_job(started["job_id"])
ok(job and "does not know this model's price" in job.get("waiting_for_user", ""), "an unknown price asks", job)
texts = ax("texts")
ok("does not know this model's price" in texts, "the bar says why", texts[:400])

# 5. 点「允许」：才提交、做完、记账（AXPress）
res = ax("click", "ai-banner-allow")
ok("clicked" in res, "pressed Allow on the bar", res)
time.sleep(3)
job, _ = mcp.call("get_job", {"job_id": started["job_id"]})
# 假 fal 对没登记的端点永远 IN_PROGRESS：看得到已经提交了、就取消它
ok(len(posts("acme/whatever")) == before + 1, "after Allow the request is sent to fal", job)
mcp.call("cancel_job", {"job_id": started["job_id"]})
job = mcp.wait_job(started["job_id"], 30)
ok(job.get("status") == "cancelled", "cancelling a running request works", job)
ok(any(e["method"] == "PUT" and "acme/whatever" in e["path"] and e["path"].endswith("/cancel") for e in server_log()), "fal was asked to cancel the request too (detached PUT)")

# 6. 「先不要」
started, err = mcp.call("generate_media", {"kind": "text_to_video", "prompt": "declined", "resolution": "1080p", "name": "declined"})
job = waiting_job(started["job_id"])
ok(job and job.get("waiting_for_user"), "another question is pending", job)
res = ax("click", "ai-banner-decline")
job = mcp.wait_job(started["job_id"], 20)
ok(job.get("status") == "cancelled" and "did not approve" in job.get("message", ""), "Not Now ends the job without spending", job)
n = len(posts("minimax/h3-max/text-to-video"))
ok(n == 0, "and nothing was sent to fal", n)

# 7. 停止：等着的问题算「不要」
started, err = mcp.call("generate_media", {"kind": "text_to_video", "prompt": "stop me", "name": "stopme"})
job = waiting_job(started["job_id"])
res = ax("click", "ai-banner-stop")
ok("clicked" in res, "pressed Stop on the bar", res)
after, err = mcp.call("get_status")
ok(err and "pressed Stop" in json.dumps(after), "the next AI call is told the user pressed Stop", after)
time.sleep(11)   # 安静够久（AISession.stopQuietSeconds）才放行
job, _ = mcp.call("get_job", {"job_id": started["job_id"]})
ok(job.get("status") == "cancelled", "Stop cancelled the waiting job (nothing was charged)", job)
status_spent = None
print(f"\n{'ALL PASSED' if fails == 0 else str(fails) + ' FAILED'}")
mcp.close()
sys.exit(1 if fails else 0)
