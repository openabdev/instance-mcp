# Requirement — sandbox agent egress to instance-mcp over the tailnet

> Recorded 2026-09-24. Implements **Phase 4** of
> [`connect-closed-loop.md`](connect-closed-loop.md): "Connect's agent (in the `openab-pty`
> sandbox) reaches macmini MCP over the tailnet." Design of record for the *macmini side*
> lives here; the *pod side* change is filed against `openabdev/openab-pty`.

## Statement

A coding CLI (kiro-cli / claude / openab) runs inside the `openab-pty` sandbox — a k8s pod or
ECS task. It must be able to call `oab-instance-mcp` on macmini
(`https://macmini.<tailnet>.ts.net:8444/mcp`) so the agent can drive the Mac (exec / screenshot
/ mouse / key / browser) as the closed-loop requirement describes.

Nothing on the macmini side needs to change to *receive* the agent — it is already a passive
tailnet service behind `tailscale serve --https=8444`, gated by `Tailscale-User-Login` **AND**
a bearer token. The gap is entirely **egress from the sandbox**: per openab-pty's architecture,
the shell (`uid 1000`, no sudo, no host creds, read-only rootfs) has **no network identity of
its own** — the tailscale sidecar is the only thing in the pod with one, and today it is
configured for *inbound* attach, not *outbound* to another tailnet node.

## Why not a proxy env var (rejected)

The obvious first idea — run the sidecar as a SOCKS5/HTTP forward proxy and set `HTTPS_PROXY`
in the shell — is **not robust**, because honoring `HTTPS_PROXY` is a per-client convention, not
an OS-enforced one:

- Node `fetch`/`undici` (claude-code and many MCP clients) **ignores** `HTTPS_PROXY` unless the
  app explicitly installs a `ProxyAgent`.
- Rust `reqwest` reads it; a raw `hyper` client or `.no_proxy()` does not.
- Go `net/http` default transport reads it; a custom `Transport` without `Proxy` set does not.

Second-order risk: MCP is **Streamable HTTP + SSE** over a long-lived connection; some HTTP
proxies buffer or mishandle the stream after `CONNECT`, so even a proxy-honoring client can
stall. We must not bet reachability on a variable we do not control and each agent implements
differently.

## Decision — openab-pty runtime exposes a loopback MCP port and forwards to macmini

The `openab-pty` runtime already binds `127.0.0.1` only and is the one component in the pod
entitled to talk to the sidecar over loopback. It gains a **second loopback listener** that the
coding agent points its `mcp.json` at:

```
agent mcp.json  →  http://127.0.0.1:<port>/mcp   (plain HTTP, loopback, no proxy, no TLS)
                        │
              openab-pty runtime (transparent reverse proxy)
                        │  injects Authorization: Bearer <scoped-token>
                        ▼
              HTTPS over the tailnet, through the sidecar's identity
                        ▼
              macmini.<tailnet>.ts.net:8444/mcp   (AuthPolicy: login AND token)
```

This makes the agent's HTTP stack irrelevant: it calls what looks like a normal local MCP
server. No proxy env, no TLS on the agent hop, no dependence on client cooperation. The problem
"will the agent honor `HTTPS_PROXY`?" disappears because there is no proxy.

### First cut: transparent reverse proxy (not MCP-aware)

The runtime forwards the HTTP request body/stream to macmini unchanged and streams the response
back. It does **not** parse MCP. This keeps streaming/SSE correct (body pass-through) and leaves
macmini's `AuthPolicy` untouched.

- **agent → runtime**: loopback plain HTTP.
- **runtime → macmini**: runtime is the TLS client to `https://…ts.net:8444`, and **injects the
  bearer token itself**. The token therefore never lands in the shell or in the agent's
  `mcp.json` — a strict improvement over handing the agent a token.
- **Binding invariant**: the new listener MUST bind `127.0.0.1` only, never `0.0.0.0`.
  Publishing it on a routable interface would break openab-pty's core invariant.

### Deferred: MCP-aware capability scoping

Parsing MCP JSON-RPC in the runtime to enforce a per-tool allowlist (e.g. deny `exec` for the
sandbox tier) is the right long-term shape but is fragile (tracks protocol versions, must handle
stream semantics). Deferred to a later slice, consistent with authn.md's deferred per-caller
capability set. Until then the scoped token grants the full tool surface, and the trust
statement is "the sandbox agent is trusted with this Mac's shell", same as a human operator —
which must be an explicit deployment choice, not a default.

## Trust model (unchanged from authn.md, restated for this path)

- The sandbox is a **lower trust tier** than a human operator. It must reach macmini with a
  **distinct, revocable, scoped** bearer token — never a human's keychain credential.
- macmini's `--allow-login` must include whatever login the sidecar enrolls as, but the bearer
  token remains the real gate (defence-in-depth: a leaked tailnet key alone → 401).
- Token injection by the runtime means the shell never holds the token; rotation is
  delete-and-redeploy on the pod side plus updating macmini if the token itself rotates.

## Split of work

| Side | Change | Scope |
|---|---|---|
| `openabdev/openab-pty` (primary) | new `[mcp_egress]` config: loopback listener, `target`, token source; transparent HTTPS reverse proxy over tailnet with bearer injection; loopback-only bind enforced; deploy manifests carry target/token via secret | this is where the feature lives |
| `oab-instance-mcp` (this repo) | **none for the first cut** — `AuthPolicy` (login AND token) is sufficient. Only touched later if 4b adds per-caller capability scoping on the macmini side | additive, deferred |

## Phasing

| Phase | Deliverable | Depends on |
|---|---|---|
| 4a | Validate with **no code**: on one pod, `socat`/`tailscale serve` a loopback port → `macmini:8444`; from the shell `curl http://127.0.0.1:<port>/healthz` → `ok` (no proxy set); point an agent's mcp.json at it and run `sys_info` with the token; **separately measure whether each agent CLI honors `HTTPS_PROXY`** and record the result | tailnet-enrolled sidecar |
| 4b | openab-pty runtime `[mcp_egress]`: loopback listener + transparent HTTPS reverse proxy + runtime-injected scoped bearer; loopback-only bind; deploy manifests | 4a |
| 4c (deferred) | MCP-aware capability scoping (per-tool allowlist), either in the runtime or as a per-caller capability set on macmini | 4b + authn.md capability work |

## Verification (4a, measurement discipline)

- The diagnostic must use the same rule as the shipping path: test the **loopback plain-HTTP →
  tailnet-HTTPS** hop, not a laptop-direct call to macmini (which already works and proves
  nothing about the pod).
- Confirm `curl` **without** any `*_PROXY` env reaches macmini through the loopback port.
- Record, per agent CLI, whether it honors `HTTPS_PROXY` — this is a fact the doc should carry,
  and it is the evidence that justifies choosing the loopback-listener design over a proxy.
- Confirm MCP streaming/SSE works end to end (a `sys_info` round-trip and one `exec` with
  incremental output), not just `/healthz`.

## Open questions

- **TLS to macmini**: runtime as TLS client to `https://…ts.net:8444` (simplest, chosen) vs TCP
  passthrough preserving SNI. Chosen path lets the runtime inject the bearer; passthrough would
  not. Confirm the runtime can resolve/reach the `…ts.net` name through the sidecar's DNS.
- **Token source on the pod**: k8s Secret / ECS secret vs minted by openab-pty's admin plane.
  Prefer the admin plane (per-session, TTL'd) if the MCP egress can be tied to a session
  lifetime; otherwise a long-lived scoped secret, documented as shell-equivalent trust.
- **One egress or per-session**: a single pod-wide egress listener vs one per PTY session. Pod-wide
  is simpler and matches "one openab-pty process = one CP agent" from openab-cp notes; revisit if
  per-session attribution is needed in macmini's `agent.log`.
