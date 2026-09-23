# oab-mac-agent

The "hands and feet" half of [openabdev/openab#1544](https://github.com/openabdev/openab/issues/1544):
a thin daemon that lives in a Mac's logged-in desktop session and exposes the machine to a
coding CLI or agent elsewhere on the tailnet as **MCP servers**. Nothing here is smart; all
the intelligence stays in the caller.

```
laptop / sandbox (tailnet)                 macmini (tailnet, Aqua session, LaunchAgents in gui/501)
┌───────────────────────┐   HTTPS (MCP)    ┌───────────────────────────────────────────────────┐
│ kiro-cli / claude …   │ ───────────────► │ tailscale serve :8444 → 127.0.0.1:8795            │
│  mcp.json:            │                  │   oab-mc-agent   (Swift)  exec / screenshot / sys_info │
│   macmini-agent   → https://macmini.<tn>.ts.net:8444/mcp                                       │
│   macmini-browser → https://macmini.<tn>.ts.net:8443/mcp                                       │
│                       │ ───────────────► │ tailscale serve :8443 → 127.0.0.1:8794            │
└───────────────────────┘                  │   @playwright/mcp (headed Chromium, persistent profile) │
                                           └───────────────────────────────────────────────────┘
```

Two servers, one pattern: bind loopback, let `tailscale serve` do TLS and identity, run as a
LaunchAgent in the GUI session so TCC-gated things (screen, later input) work. SSH already gives
you a shell; this exists for what SSH cannot reach.

- `oab-mc-agent` — this package. Swift, zero dependencies (Network.framework + ScreenCaptureKit).
- Browser — `@playwright/mcp`, not ours. See [`poc/pw-mcp/README.md`](poc/pw-mcp/README.md).
- Design notes: [`docs/requirements/connect-closed-loop.md`](docs/requirements/connect-closed-loop.md).

## Tools

| tool | what | notes |
|---|---|---|
| `sys_info` | host, OS, chip, displays, tailnet IPs, console user, TCC status | call first; tells the model what will work |
| `exec` | `zsh -f -c <command>` as the desktop user | `cwd`, `env`, `timeout_secs` (≤600), `max_output_bytes` (≤1 MiB/stream). Spawned with `POSIX_SPAWN_SETSID`; timeout → `killpg` → exit 137, `timed_out=true`. `structuredContent` carries exit/stdout/stderr/duration |
| `screenshot` | ScreenCaptureKit → JPEG/PNG as MCP `image` content | `display`, `scale` (px per point, default 1.0), `region` {x,y,w,h} crop in points, `format`, `quality`. Needs Screen Recording TCC. Read small UI text with `region` + `scale: 2` |
| `mouse` | CGEvent: `move` `click` `double_click` `right_click` `drag` `scroll` | coordinates in display points = screenshot pixels at scale 1. `modifiers`. Needs Accessibility TCC |
| `key` | CGEvent: `type` (unicode, layout-independent) / `press` combos (`cmd+shift+4`) | Needs Accessibility TCC |
| `osascript` | AppleScript / JXA via `/usr/bin/osascript` in the GUI session | `timeout_secs` (default 15). First script against an app raises an Automation consent dialog on the Mac — screenshot, then `mouse` click Allow |

The loop the tools are designed for: `screenshot` → decide → `mouse`/`key`/`osascript` → `screenshot` to confirm.
Verified 2026-09-22 from the laptop: open TextEdit, type a line, read it back, close via the save
sheet's Delete button located from a screenshot, quit — 0.15–0.8 s per call.

Planned: a streaming capture sink for OpenAB Connect (see requirement doc).

## Auth

Evaluated per request in `AuthPolicy`; the server refuses to start with nothing configured.

- `--allow-login <email>` — matches `Tailscale-User-Login`, which `tailscale serve` **injects and
  overwrites** (verified: a client-supplied header is replaced). This is the primary control.
- `--token <s>` / `--token-file <p>` — additionally require `Authorization: Bearer`, constant-time
  compared. Use when a non-Tailscale-identity caller (a sandbox pod) needs in.
- `--insecure-local` — allow bare loopback requests with no Tailscale headers. Debugging only.
- `/healthz` is unauthenticated and says only `ok`.

Trust model: `exec` is a full shell as the logged-in user. This is "my CLI on my Mac". Before a
sandboxed OAB bot gets this endpoint it needs a tool allowlist and its own token — not built.

## Build & test (on macmini; the laptop never compiles Swift)

```sh
rsync -a --delete --exclude .build --exclude .git ./ macmini:~/src/oab-mac-agent/
ssh macmini 'cd ~/src/oab-mac-agent && swift build -c release && swift test'
ssh macmini 'cd ~/src/oab-mac-agent && bash scripts/smoke.sh'   # loopback, every step time-bounded
```

`~/src` is on the internal disk on purpose: `~/build` is a RAID symlink and LaunchAgents cannot
read the RAID (TCC on external volumes).

## Deploy (run on the target)

```sh
ssh macmini 'cd ~/src/oab-mac-agent && bash scripts/deploy.sh you@example.com'
```

`deploy.sh` wraps the binary in `~/.local/oab-mac-agent/oab-mc-agent.app` (bundle id
`dev.openab.mac-agent`) so TCC grants bind to a stable identity, signs it with the
`<team-id>` Apple Development cert, installs LaunchAgent `dev.openab.mac-agent` in `gui/501`,
and runs `tailscale serve --bg --https=8444 http://127.0.0.1:8795`.

Then, once, on the Mac's own screen, System Settings → Privacy & Security:
- Screen & System Audio Recording → enable **oab-mc-agent**
- Accessibility → enable **oab-mc-agent**

then `launchctl kickstart -k gui/501/dev.openab.mac-agent`. `sys_info` reports both as `true` when
done. Grants survive re-signing with the same identity + bundle id (verified across 0.1.0→0.2.0).

Also on the Mac: `sudo pmset -a displaysleep 0`. With display sleep on, an idle Mac returns black
screenshots and, once the lock engages, drops injected input.

Client:

```sh
kiro-cli mcp add --name macmini-agent --url https://macmini.<tailnet>.ts.net:8444/mcp --scope global --timeout 30000
```

## Operate

```sh
ssh macmini 'launchctl print gui/501/dev.openab.mac-agent | grep -E "state|pid"'
ssh macmini 'tail -20 ~/Library/Logs/oab-mac-agent/agent.log'      # one line per session open / tools/call / deny
ssh macmini 'launchctl kickstart -k gui/501/dev.openab.mac-agent'  # restart
ssh macmini '/Applications/Tailscale.app/Contents/MacOS/Tailscale serve status'
curl -s https://macmini.<tailnet>.ts.net:8444/healthz
```

Measured from the laptop: `sys_info` 0.75 s, `exec` 0.47 s, a 1 s exec timeout returns in 1.6 s.

## Gotchas (each one cost a cycle)

- **Keep the `LoopbackHTTPServer` a global.** Declared inside `do {}` it was released at the
  end of the block; the listener stayed bound, accepted connections, and never answered —
  the `[weak self]` handlers were no-ops. `curl` hung to its timeout with no server log line.
- **`codesign` over SSH → `errSecInternalComponent`** for anything in the login keychain, with
  or without `ssh -t`. Sign from a dedicated keychain whose password is on disk
  (`~/.config/signing/`), passing `--keychain` explicitly.
- **`kiro-cli mcp add --force` truncated `~/.kiro/settings/mcp.json` to 0 bytes** the second
  time it was used in a session. Back the file up before `mcp add`, or edit it by hand.
- **macOS has no `timeout`.** Remote scripts bound steps with `perl -e 'alarm shift; exec @ARGV'`
  and `curl -m`. Write them as bash files: zsh does not word-split `$VAR`, so
  `C="curl -s -m 10"; $C …` is "command not found".
- **`tccutil reset ScreenCapture <bundle-id>` does not make the prompt appear.** After the
  first denial the system records it and further capture attempts fail silently; the grant
  has to be toggled in System Settings on the machine's own display.
- **Display sleep = black screenshots.** macmini shipped with `displaysleep 3`; the first
  screenshot after a quiet spell was solid black with a cursor. `pmset -a displaysleep 0`.
- **A stuck `osascript` is usually a consent dialog.** First AppleEvent to an app pops an
  Automation prompt on the Mac; the call blocks until answered. Over SSH the prompt is attributed
  to `sshd-keygen-wrapper` — decline those; only the agent bundle should hold Automation grants.
- **`launchctl bootout` returns before the job is gone**; an immediate `bootstrap` fails and,
  under `set -e`, took the deploy script with it — leaving no agent running. Poll until
  `launchctl print` fails before bootstrapping.
- **Model vision vs capture.** At scale 0.5 a 1080p menu bar is ~12 px tall and the model refuses
  to read it (correctly). Default is now scale 1.0; for text, crop with `region` at `scale: 2`.
- `/tmp` is `/private/tmp` — `exec` reports resolved paths.
- `zsh -f` is deliberate: the user's `.zshenv` sources a RAID-path `.cargo/env` that fails
  under launchd. Callers get a clean shell; set `env` explicitly if they need PATH additions.
