# Requirement — reverse attach: macmini dials the sandbox, the sandbox has no egress

> Recorded 2026-09-24. Implements **Phase 4** of
> [`connect-closed-loop.md`](connect-closed-loop.md): "Connect's agent (in the `openab-pty`
> sandbox) reaches macmini MCP over the tailnet." Supersedes the earlier *sandbox-egress*
> draft of the same day, which is summarised under "Rejected" below.

## Statement

A coding CLI (kiro-cli / claude / openab) runs inside the `openab-pty` sandbox — a k8s pod or
ECS task — and must be able to call `oab-instance-mcp` tools on macmini (screenshot / mouse /
key / osascript / exec) so the agent can drive the Mac while the human watches in Connect.

The sandbox shell has **no network identity of its own** (`uid 1000`, no host creds, read-only
rootfs); the tailscale sidecar is the pod's only tailnet identity and it is **inbound-only**
(tailnet → sidecar → loopback runtime). Every earlier idea started from "give the sandbox an
egress path". This document starts from the opposite premise: **the sandbox gets no egress at
all — macmini connects *in*.**

## Rejected — every egress-based variant shares one root flaw

Once the sandbox has *any* outbound tailnet path it is effectively a tailnet node, and
everything after that is patching:

| Variant | Flaw |
|---|---|
| sidecar as SOCKS/HTTP proxy + `HTTPS_PROXY` in the shell | honoring `HTTPS_PROXY` is a per-client convention (Node `fetch`/undici ignores it; raw `hyper`/custom Go transports ignore it); MCP's Streamable HTTP + SSE is proxy-hostile |
| agent holds the bearer token and connects itself | token lands in the shell (`uid 1000`, prompt-injectable) — breaks openab-pty's "the shell never holds a credential" invariant |
| runtime holds the token and reverse-proxies to macmini (the earlier draft) | keeps the token out of the shell, but a compromised agent can still bind its own loopback relay to the sidecar's egress and reach **any** tailnet node; needs destination lock-down + ACLs, and per-tool scoping would mean parsing MCP inside a proxy (fragile) |

All three require changing the sidecar from inbound-only to inbound+egress. Removing egress
removes the whole class of problems.

## Decision — reverse attach

```
  openab-pty pod                                        macmini
  ┌──────────────────────────────────────────┐          ┌──────────────────────────────┐
  │  agent CLI          runtime              │          │  oab-instance-mcp            │
  │  ┌──────────┐    ┌──────────────────┐    │          │  ┌────────────────────────┐  │
  │  │ mcp.json │    │ loopback MCP     │    │          │  │ reverse-attach client  │  │
  │  │127.0.0.1 ├───►│ listener (mux)   │    │          │  │  holds the credential  │  │
  │  │ no token │    │        ▲         │    │          │  │  picks a tool profile  │  │
  │  └──────────┘    │        │         │    │          │  │  (sandbox: no exec)    │  │
  │                  │ /tools/attach    │◄───┼── WSS ───┼──┤                        │  │
  │                  │ (sha256 verifier)│    │ inbound  │  └────────────────────────┘  │
  │                  └──────────────────┘    │  only    └──────────────────────────────┘
  │   sidecar: inbound only — UNCHANGED      │                       ▲
  │   no egress of any kind                  │                       │ "lend my Mac to this
  └──────────────────────────────────────────┘                       │  session, 1h" — human,
                                                                     │  in OpenAB Connect
```

1. **openab-pty runtime** gains an inbound endpoint `WS /tools/attach` on its existing
   loopback listener (reached through the sidecar's existing `tailscale serve`, exactly like
   `/pty/{session}` today), credentialed the same way the admin plane is: the pod stores only
   a `sha256:` **verifier**, never a usable secret.
2. **macmini (`oab-instance-mcp`)** gains a **reverse-attach client**: it dials
   `wss://<pod>.<tailnet>.ts.net/tools/attach`, authenticates with a credential *it* holds, and
   serves MCP over that socket.
3. The runtime exposes a **loopback MCP listener** (`http://127.0.0.1:<port>/mcp`) for the
   agent and multiplexes requests over the reverse socket. The agent's `mcp.json` points at a
   plain local URL: no token, no TLS, no proxy, and its HTTP stack is irrelevant.
4. **Tool profile is chosen by macmini per attach.** macmini *is* the MCP server, so scoping
   is a per-connection tool list in `MCPServer` — `tools/list` returns the profile's tools and
   `tools/call` rejects anything else. No MCP parsing in a proxy. The `sandbox` profile
   excludes `exec`/`exec_start` (or gates them on Connect approval, below).

### Who tells macmini which pod to dial — the human, in Connect

Pods are ephemeral; macmini cannot be configured with them. Connect already lists both PTY
sessions and Mac agents. The user selects a PTY session and chooses **"lend my Mac to this
agent"** with a profile and a TTL; Connect (human credential, over the tailnet) calls a new
admin endpoint on `oab-instance-mcp` — `POST /attach {runtime, session, profile, ttl}` — and
macmini dials in. The grant is **explicit, per-session, time-bounded, revocable**, and made
in the same app where the human watches the screen. This completes the closed loop: the human
watches *and* authorises from one place.

Alternative rendezvous (both sides dial `openab-cp`) is viable and aligns with the openab-pty
→ CP-runtime direction, but adds a third component; not needed for the first cut.

## Threat model — what this does and does not stop

| Threat | Result |
|---|---|
| sandbox needs a tailnet egress path | **none needed**; sidecar unchanged |
| credential in the pod that a compromised shell could steal | **none** — pod holds a sha256 verifier only; a verifier cannot be used to connect anywhere |
| compromised agent reaches other tailnet nodes | **impossible** — no egress to bypass through |
| compromised agent uses macmini's full shell via `exec` | **blocked by profile** — the `sandbox` profile omits `exec`, or requires a human tap in Connect (the human is already watching the screen) |
| compromised agent calls the tools it *was* granted | **residual, by design** — giving an agent hands carries this in every design; the difference is the hands are exactly as large as the human chose, for as long as they chose |
| macmini's attach credential leaks | attacker could serve a fake `/tools/attach`? No — the credential authenticates macmini *to the pod*; a leaked one lets an attacker impersonate macmini to that pod, not reach macmini. Mint per-attach, TTL'd, revoke by deleting the verifier |

## Split of work

| Side | Change |
|---|---|
| `openabdev/openab-pty` | `WS /tools/attach` inbound endpoint with sha256-verifier auth (reuse admin-plane pattern); loopback MCP listener (`127.0.0.1` only, enforced) that multiplexes to the attached socket; admin op to mint/revoke an attach verifier for a session; deploy manifests unchanged (sidecar stays inbound-only) |
| `oab-instance-mcp` (this repo) | reverse-attach client (WSS dial, reconnect, teardown when the pod disappears); per-connection **tool profiles** in `MCPServer` (`owner` = everything, `sandbox` = no `exec*`); admin endpoint `POST /attach` for Connect (human-credentialed, existing `AuthPolicy`); optional `exec` approval hop via Connect |
| OpenAB Connect | "lend my Mac to this session" action → `POST /attach`; approval prompt for gated tools |

## Phasing

| Phase | Deliverable | Depends on |
|---|---|---|
| 4a | **Protocol spike, no product code**: `websocat`/`socat` a reverse WS from macmini to a pod's loopback through the existing `tailscale serve`; prove MCP round-trips (`sys_info`, one streaming call) from a CLI pointed at the pod's loopback port | a tailnet-enrolled pod |
| 4b | openab-pty `/tools/attach` + loopback mux; instance-mcp reverse-attach client + `sandbox` profile (no `exec*`); manual `POST /attach` via curl | 4a |
| 4c | Connect "lend my Mac" UI + TTL + revoke; `exec` approval prompt | 4b + Connect |

## Verification (4a, measurement discipline)

- Test the **real hop**: macmini → pod inbound → loopback mux → agent. A laptop-direct call to
  macmini proves nothing about the pod.
- From inside the shell: `curl http://127.0.0.1:<port>/healthz` with **no** `*_PROXY` set.
- One `sys_info` and one streaming call end to end; confirm `tools/list` under the `sandbox`
  profile does **not** contain `exec`, and that a forced `tools/call exec` is rejected.
- Confirm from inside the shell that **no** outbound tailnet path exists (`curl` to another
  tailnet node fails) — this is the property the design is buying.

## Open questions

- Reconnect semantics when the pod restarts under the same session name; who owns retry
  (macmini, since it is the dialer).
- One attach per PTY session vs one per pod; per-session gives clean attribution in
  `agent.log` and matches the Connect grant model.
- Whether `exec` in the `sandbox` profile is "absent" or "present but approval-gated"; start
  with absent, add gating when Connect has the prompt.
- Framing on the reverse socket: raw MCP JSON-RPC frames over WS is simplest; the mux only
  needs a per-request correlation id it already has (`id`).
