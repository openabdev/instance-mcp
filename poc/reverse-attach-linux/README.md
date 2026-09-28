# reverse-attach (Linux hands node, Rust PoC)

Part of [#27](https://github.com/openabdev/instance-mcp/issues/27) (hands-node registry) and
[#15](https://github.com/openabdev/instance-mcp/issues/15) (Linux-first Rust port). A single
self-contained binary that makes a Linux box a lendable "hands" node for an openab-pty session,
mirroring the Swift `ReverseAttachClient` / `POST /attach` contract:

- `POST /attach` `{runtime, session, profile, ttl_secs, secret | admin_credential}` → grant.
  Exactly one of `secret` / `admin_credential`; the latter mints at the runtime's
  `POST /admin/sessions/{session}/tools-attach` with `{"ttl_secs": N}` (ws:// runtimes only in
  this PoC) and forwards the TTL end to end (#25 semantics).
- Dial loop: `GET ws://…/tools/attach/{session}` with `Authorization: Bearer <secret>`, redial
  1 s → 30 s backoff until the grant deadline. Disposition per openab-pty §9.2: close `4001`
  expired / `4002` replaced / `4004` session ended / `4010` revoked and handshake non-2xx/429/5xx
  → **stop**; `1000` / `4006` / other / 2xx / 429 / 5xx → **redial**. Same table the
  `reverse-attach-conformance` suite (#24) checks 23/23 against the Swift oracle.
- MCP over the socket: `initialize`, `tools/list`, `tools/call`; notifications get no reply;
  ping → pong. Profiles: `owner` = `sys_info` `screenshot` `exec`; `sandbox` = no `exec`
  (`tools/list` omits it and a forced call is an error).
- `GET /attachments` lists grants with live state (`dialing` / `attached` /
  `stopped(revoked)` / `stopped(handshakeRejected(401))` / `ended(deadline)` …).

Deps: `serde_json` + `tungstenite` (rustls). Sync std threads, no tokio. ~28 KB.

## Verified on rpi1 (Debian 12, aarch64, Rust 1.98) — 2026-09-27

```sh
cargo build --release          # 31 s cold, 2.2 MB binary
bash smoke.sh                  # RESULT: 28 passed, 0 failed
```

`smoke.sh` runs the binary against `mock_runtime.py` (stdlib-only mock openab-pty: mint endpoint
+ WS attach endpoint that drives a scripted MCP turn and closes with a scripted code). Covered:

| area | checks |
|---|---|
| validation | non-ws runtime, bad session, both/neither credential, ttl 0, wrong admin → `400 mint failed: mint HTTP 401`, 404 route |
| mint path | `ttl_secs=60` seen by the runtime's mint endpoint; `expires_in_secs=60` in the grant |
| redial / stop | close `1000` → redialed after 1 s; close `4010` → `stopped(revoked)`; wrong secret → handshake 401 → `stopped(handshakeRejected(401))` with **exactly one** attempt; unreachable runtime → backoff → `ended(deadline)` |
| MCP | `serverInfo.name=instance-mcp-rpi`; owner list = `sys_info,screenshot,exec`; `sys_info.hostname=rpi1`; `exec` ran on the node; unknown tool / method → `-32601`; notification silent; ping → pong |
| sandbox | list = `sys_info,screenshot`; forced `exec` → error, not executed |
| close handshake | client echoes the Close frame (was a bare EOF before the `socket.flush()` fix in `dial_loop`) |

## Direct `/mcp` for OpenAB Connect's Screens pane (added 2026-09-28)

The same binary now also serves MCP Streamable-HTTP (JSON mode) on `POST /mcp`, gated by an
`AuthPolicy` with the Swift daemon's semantics — `MCP_TOKEN` / `MCP_TOKEN_FILE` (bearer,
constant-time) AND `MCP_ALLOW_LOGIN` (matched against the `Tailscale-User-Login` header that
`tailscale serve` injects); `MCP_INSECURE_LOCAL=1` for loopback debugging; refuses to start with
nothing set. `/healthz` is open. `screenshot` returns MCP `image` content (grim → PNG; a `jpeg`
request falls back to PNG because Debian's grim lacks libjpeg — Connect decodes by content).
`sys_info` carries the `host` / `displays` / `permissions.screen_recording` / `agent.version`
fields the Screens pane reads.

On rpi1: systemd user unit `oab-instance-mcp.service` (BIND 127.0.0.1:8795, seat env
`WAYLAND_DISPLAY=wayland-0`, linger on) + `tailscale serve --bg --https=8444 http://127.0.0.1:8795`
→ `https://rpi1.tailb836bb.ts.net:8444/mcp`. Verified from the laptop: wrong token 401,
initialize 200 with `Mcp-Session-Id`, `sys_info` host=rpi1 displays=1, Connect-shaped screenshot
call (`display 0, scale 1, quality 0.6, format jpeg`) → 1920×1080 PNG in 1.35 s. Pi OS's labwc
desktop keeps a 1920×1080 headless output alive with no monitor attached, so no sway needed.

## Not yet (vs the Swift implementation)

- `/mcp` has no real session table (an `Mcp-Session-Id` is issued but not checked) and no SSE stream.
- Screenshot is PNG only (≈2 MB per 1080p frame); Connect polls at ≤2 FPS, so expect ~4 MB/s. A
  JPEG encoder in-process (or a grim with libjpeg) is the fix.
- `wss://` runtimes: dial works (rustls), mint over https does not.
- Replacement semantics (new grant for same runtime+session replaces the old one) and
  `DELETE /attach/{id}` are not implemented; grants are append-only in memory.
- `screenshot` shells out to `grim` (needs a Wayland seat, see #23) and returns a path, not MCP
  `image` content. No `mouse` / `key` (wlrctl, #26).
- Real-runtime test against the p1 openab-pty pod is pending: rpi1 is **not on the tailnet**
  (no `tailscale` binary; `100.111.174.31:8090` times out) and the pod's `PTY_ADMIN_HASH` is a
  hash, so the admin credential must come from the operator.
