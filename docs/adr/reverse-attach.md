# ADR: Reverse Attach — macmini dials the sandbox

- **Status:** Proposed
- **Date:** 2026-09-25
- **Requirement:** [`docs/requirements/reverse-attach.md`](../requirements/reverse-attach.md) (full design, threat model, phasing)
- **Related:** [openabdev/openab#1544](https://github.com/openabdev/openab/issues/1544) (brain/hands split), [`connect-closed-loop.md`](../requirements/connect-closed-loop.md) Phase 4, [`sandbox-adapter.md`](sandbox-adapter.md)

## Context

A coding CLI (kiro-cli / claude / openab) running inside the `openab-pty` sandbox — a k8s pod
or an ECS Fargate task — must be able to call `oab-instance-mcp` tools on a Mac (screenshot,
mouse, key, osascript, exec) so the agent can drive the Mac while the human watches in OpenAB
Connect.

Three facts about the sandbox constrain the answer:

1. The shell runs as `uid 1000` with no host credentials and a read-only rootfs. openab-pty's
   standing invariant is that **the shell never holds a credential**.
2. The tailscale sidecar is the pod's only tailnet identity and it is **inbound-only**:
   tailnet → sidecar → loopback runtime, via `tailscale serve`.
3. The sidecar runs `--tun=userspace-networking` on both k8s and ECS. There is no tun device,
   so "egress" does not exist by default; it can only be added as a SOCKS5/HTTP proxy that each
   client must opt into. Kernel mode would need `NET_ADMIN` + `/dev/net/tun`, which Fargate
   does not provide.

Every earlier draft started from "give the sandbox an egress path to the Mac". This ADR records
why we start from the opposite premise.

## Alternatives considered

| Alternative | Why rejected |
|---|---|
| **Sidecar as SOCKS/HTTP proxy + `HTTPS_PROXY` in the shell** | Honouring proxy env vars is a per-client convention (Node `fetch`/undici ignores it; raw `hyper`/custom Go transports ignore it). MCP Streamable HTTP + SSE is proxy-hostile. The bearer token lands in the shell — breaks invariant 1. |
| **Agent holds the bearer token and connects to the Mac itself** | Token in the shell (`uid 1000`, prompt-injectable). Breaks invariant 1 outright. |
| **Runtime holds the token and reverse-proxies to the Mac** | Keeps the token out of the shell, but a compromised agent can bind its own loopback relay to the sidecar's egress and reach **any** tailnet node. Needs destination lock-down + ACLs; per-tool scoping would mean parsing MCP inside a proxy. |
| **ACL-scoped egress** — the previous variant plus a Tailscale ACL `tag:oab-pty → tag:instance-mcp:<port>` | Viable, not chosen. Fixes the "any tailnet node" flaw, but: egress is still a per-client proxy opt-in (fact 3); trust becomes **per tag, per port** — every pod with the tag reaches every Mac with the other tag until the policy is edited, so per-session grant / TTL / revoke must be rebuilt as a server-side allowlist; the security boundary now includes the ACL file (the default `src:["*"], dst:["*:*"]` rule silently defeats the tag rule; `serve :443` on the Mac multiplexes other services, so `:443` grants all of them). Kept as the documented fallback — see the requirement doc for the exact conditions. |
| **Rendezvous via `openab-cp`** (both sides dial the control plane) | Consistent with the openab-pty → CP-runtime direction, but the pod would still need egress to dial the CP, and it adds a third component to the first cut. Revisit when openab-pty becomes a CP runtime. |

## Decision

**The sandbox gets no egress at all. The Mac dials the pod.**

1. **openab-pty runtime** gains an inbound endpoint `WS /tools/attach` on its existing loopback
   listener, reached through the sidecar's existing `tailscale serve` exactly like
   `/pty/{session}`. It is credentialed like the admin plane: the pod stores a `sha256:`
   **verifier** only, never a usable secret.
2. **`oab-instance-mcp`** gains a **reverse-attach client**: it dials
   `wss://<pod>.<tailnet>.ts.net/tools/attach` with a credential *it* holds and serves MCP over
   that socket.
3. The runtime exposes a **loopback MCP listener** (`http://127.0.0.1:<port>/mcp`) to the CLI
   and multiplexes requests over the reverse socket by JSON-RPC `id`. The CLI's `mcp.json`
   points at a plain local URL — no token, no TLS, no proxy; its HTTP stack is irrelevant.
4. **The Mac chooses the tool profile per attach.** The Mac *is* the MCP server, so scoping is
   a per-connection tool list in `MCPServer` (`owner` = everything, `sandbox` = no `exec*`).
   No MCP parsing in a proxy.
5. **The human decides which pod the Mac dials**, from OpenAB Connect (Mac) **or OpenAB Remote
   (iPhone)**: pick a PTY session → "lend my Mac to this agent" with profile + TTL → the client
   calls `POST /attach {runtime, session, profile, ttl}` on `oab-instance-mcp` with the human's
   credential → the Mac mints the attach secret, installs its verifier in the pod, and dials in.
   The grant lives on the Mac: explicit, per-session, time-bounded, revocable from either
   client, attributed to the human login; the granting device need not stay online.

### Prior art

This is the OpenClaw node ↔ gateway shape: nodes (the side with hands) dial a WebSocket hub,
pass a human pairing approval, advertise capabilities, and the agent's tool calls are routed
over that socket. The same reasoning appears in `cloudflared`/ngrok tunnels, GitHub Actions
self-hosted runners, and `ssh -R`. The analogy inverts in one place: OpenClaw's hub is
long-lived and its nodes ephemeral; here the hub (pod) is ephemeral and the node (the Mac) is
long-lived — which is why the Mac must be *told* whom to dial (step 5) and why retry ownership
sits on the Mac.

## Consequences

**Gained**

- Sidecar and deploy manifests unchanged; works on Fargate as-is (userspace mode, no tun).
- No credential in the pod that a compromised shell could use. A verifier cannot connect
  anywhere.
- A compromised agent cannot reach any tailnet node: there is nothing to bypass through, and an
  over-permissive Tailscale ACL changes nothing.
- Per-session grant, TTL and revoke are native (delete the verifier), not a layer on top.
- Tool scoping is server-side and exact; `exec` can later be approval-gated in Connect without
  touching the pod.

**Paid**

- New code on both sides: `WS /tools/attach` + loopback mux in openab-pty; WS client +
  per-connection tool list + `POST /attach` in instance-mcp; a "lend my Mac" action in Connect
  and Remote.
  Both runtimes already have the building blocks (WS handling, verifier store, `MCPServer`).
- "Who dials whom" needs Connect (or a later CP rendezvous) — the Mac cannot discover pods.
- Retry/reconnect is the Mac's job. Pod recreated ⇒ verifier gone ⇒ Connect re-mints; the Mac
  keeps redialling for the remainder of the grant TTL.
- **Assumption that must hold in deployment: the k8s node is not itself a tailnet member.** If it
  is, pods reach the whole tailnet through the node's tailscale routing regardless of the
  sidecar (measured on p1, 2026-09-26; see the requirement doc's 4a results). Document it in
  the openab-pty k8s how-to; opt-in egress `NetworkPolicy` if the node must run tailscaled.
- Residual, by design: a compromised agent can call the tools it *was* granted. Every design
  that gives an agent hands carries this; here the hands are exactly as large, and last exactly
  as long, as the human chose.

## Non-goals

- Egress from the sandbox of any kind. If reverse attach proves unworkable, the fallback is
  ACL-scoped egress under the conditions listed in the requirement doc, as a separate ADR.
- Pod discovery on the Mac. The Mac dials only what `POST /attach` tells it to.
- A new wire protocol. The reverse socket carries plain MCP JSON-RPC frames.

## Acceptance criteria

Verified on the real hop (Mac → pod inbound → loopback mux → CLI), never Mac-direct:

- From inside the shell, with no `*_PROXY` set: `curl http://127.0.0.1:<port>/healthz` succeeds
  while attached.
- One `sys_info` and one streaming call round-trip end to end.
- `tools/list` under the `sandbox` profile contains no `exec*`; a forced `tools/call exec` is
  rejected.
- Deleting the attach verifier (or TTL expiry) closes the socket; the CLI's next call fails
  cleanly and `tools/list` reports "not attached" rather than an error.
- From inside the shell, `curl` to any other tailnet node **fails** — the property this
  decision buys.
