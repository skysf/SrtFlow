#!/usr/bin/env python3
"""扮成 AI 客户端驱动测试版（MCP 冒烟）：起 App 包里的 srtflow-mcp，按老一代握手，一个一个发工具调用，
打印结果；look 回的图存成 jpg（再用看图的工具打开看）。流程与注意事项见 docs/testing/gui-smoke-testing.md「四之七」。

用法：client.py <calls.json> <输出目录> [--full]
calls.json：[{"name": "get_status", "arguments": {}, "timeout": 150}, ...]（timeout 可省，秒）
环境变量 SRTFLOW_MCP_HELPER：换一个小程序（默认测试版里那一个）。
"""
import base64
import json
import os
import select
import subprocess
import sys
import time

HELPER = os.environ.get("SRTFLOW_MCP_HELPER", "/Applications/SrtFlow Beta.app/Contents/Helpers/srtflow-mcp")


def read_reply(proc, want_id, timeout):
    deadline = time.time() + timeout
    buffer = b""
    while time.time() < deadline:
        ready, _, _ = select.select([proc.stdout], [], [], 1.0)
        if not ready:
            continue
        chunk = os.read(proc.stdout.fileno(), 1 << 20)
        if not chunk:
            break
        buffer += chunk
        while b"\n" in buffer:
            line, buffer = buffer.split(b"\n", 1)
            if not line.strip():
                continue
            message = json.loads(line)
            if message.get("id") == want_id:
                return message
    return None


def main():
    calls = json.load(open(sys.argv[1]))
    outdir = sys.argv[2]
    full = "--full" in sys.argv
    os.makedirs(outdir, exist_ok=True)
    proc = subprocess.Popen([HELPER], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)

    def send(message):
        proc.stdin.write((json.dumps(message, ensure_ascii=False) + "\n").encode())
        proc.stdin.flush()

    send({"jsonrpc": "2.0", "id": 0, "method": "initialize",
          "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "smoke-claude", "version": "1"}}})
    init = read_reply(proc, 0, 30)
    print("initialize:", (init or {}).get("result", {}).get("serverInfo"))
    send({"jsonrpc": "2.0", "method": "notifications/initialized"})
    for index, call in enumerate(calls, start=1):
        started = time.time()
        send({"jsonrpc": "2.0", "id": index, "method": "tools/call",
              "params": {"name": call["name"], "arguments": call.get("arguments", {})}})
        reply = read_reply(proc, index, call.get("timeout", 150))
        took = time.time() - started
        print(f"\n=== {index}. {call['name']} {json.dumps(call.get('arguments', {}), ensure_ascii=False)} ({took:.1f}s)")
        if reply is None:
            print("  NO REPLY")
            continue
        result = reply.get("result") or {}
        if "error" in reply:
            print("  RPC ERROR:", reply["error"])
            continue
        if result.get("isError"):
            print("  isError: true")
        for position, item in enumerate(result.get("content", [])):
            if item.get("type") == "text":
                text = item.get("text", "")
                print("  " + (text if full or len(text) < 3000 else text[:3000] + f" …(+{len(text) - 3000} chars)"))
            elif item.get("type") == "image":
                data = base64.b64decode(item.get("data", ""))
                path = os.path.join(outdir, f"{index:02d}-{call['name']}-{position}.jpg")
                open(path, "wb").write(data)
                print(f"  [image {item.get('mimeType')} {len(data)} bytes → {path}]")
    proc.stdin.close()
    proc.wait(timeout=30)


if __name__ == "__main__":
    main()
