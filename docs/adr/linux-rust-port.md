# ADR: Linux-first Rust port — one core, per-OS backends

- **Status:** Proposed
- **Date:** 2026-09-27
- **Related:** [openabdev/instance-mcp#15](https://github.com/openabdev/instance-mcp/issues/15) (FR + phased plan + arch diagrams), [`reverse-attach.md`](reverse-attach.md), [`sandbox-adapter.md`](sandbox-adapter.md)

## Context

`oab-instance-mcp` today is a Swift package targeting `.macOS(.v14)`, ~3,073 lines, linking
ScreenCaptureKit / CoreGraphics / Network. It lets a coding CLI drive a machine via MCP tools
(screenshot, mouse, key, exec, sysinfo, osascript).

The strategic target is shifting: **Linux is a first-class citizen, arguably the primary one.**
Cheap Linux mini PCs and VMs are easy to acquire and scale horizontally; a Mac mini is
expensive and comparatively rare. We should optimize for deploying many inexpensive Linux
nodes, which favors a single static binary, trivial cross-compile (x86_64 + arm64), minimal
runtime deps, and a strong Linux systems ecosystem.

Analysis of the current codebase makes the port tractable:

- **~62% is platform-agnostic** (pure Foundation in spirit): MCP server/dispatch, JSON-RPC,
  HTTP/1.1, auth policy, reverse-attach, upstream MCP proxy, exec / async-exec / job registry.
- **~640 lines across 5 files are platform-specific**: Input (CGEvent x27), Screenshot
  (ScreenCaptureKit), SysInfo (CGDisplay/sysctl/TCC), osascript (AppleScript), plus the
  Network.framework transport.

Target environment verified on `rpi1` (Raspberry Pi 5): aarch64, Debian 13 (trixie), labwc
(Wayland) + lightdm, `grim`/`wlr-randr`/`scrot` already installed, `/dev/uinput` present
(root-only), Swift not installed. Crucially, most platform-specific features can shell out to
existing Linux CLIs (grim for capture, ydotool for input, /proc for sysinfo), which
substantially de-risks a rewrite regardless of language.

## Alternatives considered

| Alternative | Why rejected |
|---|---|
| **Swift for Linux (keep one Swift codebase, reuse ~62%)** | Reuses the most code, but Swift-on-Linux has a weak systems ecosystem (uinput/Wayland need hand-rolled C FFI, few examples), heavier deployment (runtime/shared libs vs a static binary), and awkward cross-compile — all of which fight the Linux-first, scale-to-cheap-nodes goal. |
| **Immediately rewrite everything (macOS included) in Rust, drop Swift now** | Cleanest end state (single codebase) but throws away the working Swift build up front and front-loads the largest effort, including re-binding newer macOS frameworks (ScreenCaptureKit) via objc2 before Linux even ships. Delays the strategic Linux target. |
| **Two permanent codebases (Swift macOS + Rust Linux, no convergence)** | Ships Linux fast but locks in a permanent two-codebase sync trap: MCP protocol/behavior must be kept in lockstep by hand forever. |
| **Node/TypeScript or Go rewrite** | Both deploy reasonably, but Rust wins on single static binary + no runtime, best-in-class Linux systems crates (evdev/uinput, wayland, sysinfo), and first-class cross-compile for x86_64 + arm64; it is also the strongest path to later re-unify macOS via FFI. |

## Decision

**Rewrite in Rust, Linux-first, as one cross-platform core with per-OS backends; keep Swift as
a transitional macOS backend until the Rust macOS backend reaches parity, then retire it.**

1. **Phase 1 — Rust Linux, cross-platform by design.** Write the Rust MCP core (HTTP transport,
   JSON-RPC, dispatch, auth + reverse-attach, exec / async-exec / job registry, upstream proxy)
   and a solid Linux backend. All platform-specific behavior sits behind a `PlatformBackend`
   trait selected via `#[cfg(target_os)]`; the core never assumes an OS. Linux backend:
   screenshot via `grim`, input via `ydotool`/`/dev/uinput` (udev rule for non-root), sysinfo
   via `/proc` + `/sys` + `wlr-randr`. Drop `osascript` (no Linux equivalent).
2. **Phase 2 — add the macOS backend (FFI) in the same Rust codebase.** Implement the macOS
   `PlatformBackend` with `objc2` / `core-graphics` (CGEvent input, ScreenCaptureKit capture,
   sysctl/TCC sysinfo). This converges to a single unified Rust codebase.
3. **Phase 3 — retire Swift.** The existing Swift macOS build keeps serving production during
   Phase 1–2. Once the Rust macOS backend reaches parity and is validated, retire Swift.

Rationale: don't discard the working Swift build up front; avoid the permanent two-codebase
sync trap (one Rust core, only the thin backend forks by `#[cfg]`); Linux (the strategic
primary target) ships soonest; macOS converges later without rewriting the core.

Deployment target: one static binary per arch (x86_64 + arm64), scp-and-run, minimal deps.

### Prior art

The "one core, per-OS backend behind a trait" shape is standard in Rust cross-platform tools
(ripgrep, alacritty, wezterm) which isolate OS specifics behind `#[cfg(target_os)]` while
sharing the bulk of the logic. Shelling out to `grim`/`ydotool` rather than binding Wayland
directly mirrors how many Linux automation tools stay compositor-agnostic. Retiring an
incumbent implementation only after a reimplementation reaches parity is the usual
strangler-fig migration.

## Validation

Phase 1 rests on three assumptions to confirm with a small PoC on `rpi1` before marking this
ADR Accepted: (a) a Rust MCP-over-HTTP server handles `initialize` + tool dispatch; (b)
`sys_info` reads /proc + `wlr-randr`; (c) `screenshot` shells out to `grim`. On success, update
Status to Accepted and note "validated by PoC on rpi1".
