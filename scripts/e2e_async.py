#!/usr/bin/env python3
# End-to-end driver: exec_start a build on the RAID path, poll incrementally, print result.
import json, subprocess, sys, time, urllib.request

BASE = "http://127.0.0.1:8795/mcp"
HDR = ["-H", "Content-Type: application/json", "-H", "Connection: close",
       "-H", "Tailscale-User-Login: you@example.com"]

def curl(body, sid=None, want_headers=False):
    args = ["curl", "-s", "-m", "60", "-X", "POST", BASE] + HDR
    if sid: args += ["-H", f"Mcp-Session-Id: {sid}"]
    if want_headers: args += ["-D", "-", "-o", "/dev/null"]
    args += ["-d", json.dumps(body)]
    return subprocess.run(args, capture_output=True, text=True).stdout

# initialize
h = curl({"jsonrpc":"2.0","id":1,"method":"initialize",
          "params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"e2e","version":"1"}}},
         want_headers=True)
sid = next(l.split(":",1)[1].strip() for l in h.splitlines() if l.lower().startswith("mcp-session-id"))

def call(name, args, id=9):
    r = curl({"jsonrpc":"2.0","id":id,"method":"tools/call","params":{"name":name,"arguments":args}}, sid=sid)
    return json.loads(r)["result"]["structuredContent"]

CMD = sys.argv[1] if len(sys.argv) > 1 else "echo BUILD-START; ls; sleep 1; echo BUILD-DONE"
CWD = sys.argv[2] if len(sys.argv) > 2 else "~/build/oab-pty-mac"

start = call("exec_start", {"command": CMD, "cwd": CWD, "timeout_secs": 120})
print("START:", start.get("job_id"), "pid", start.get("pid"), "state", start.get("state"))
jid = start["job_id"]

out_next = err_next = 0
for _ in range(120):
    p = call("exec_poll", {"job_id": jid, "stdout_since": out_next, "stderr_since": err_next})
    so, se = p.get("stdout",""), p.get("stderr","")
    if so: sys.stdout.write(so); sys.stdout.flush()
    if se: sys.stderr.write("[E]"+se); sys.stderr.flush()
    out_next, err_next = p["stdout_next"], p["stderr_next"]
    if p["state"] != "running":
        print(f"\n=== FINAL state={p['state']} exit={p.get('exit_code')} out_path={p.get('out_path')} ===")
        break
    time.sleep(1)
else:
    print("=== did not finish, cancelling ===")
    print(call("exec_cancel", {"job_id": jid}))
