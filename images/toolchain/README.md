# oab-toolchain

The sandbox image used by the sandbox adapter ([ADR](../../docs/adr/sandbox-adapter.md), tracking issue [#1](https://github.com/openabdev/instance-mcp/issues/1)).

## What's inside

- Python 3 (+pip, venv), Node.js 22 LTS (+npm), git, GitHub CLI (`gh`)
- Utilities: jq, ripgrep, curl, unzip/zip, less, procps
- Non-root user `sandbox` (uid 1000), workspace at `/workspace`
- Job-output directory `/var/log/oab-jobs/` (adapter contract path for `sandbox_exec_start`)

Deliberately **not** inside: any credential, any host mount, sudo. Per-session secrets (e.g. `GH_TOKEN`) are injected via `sandbox_exec` env by the caller.

## Build

```sh
# Local (current arch)
docker build -t oab-toolchain images/toolchain

# Multi-arch (arm64: Mac mini / Pi; amd64: Intel nodes)
docker buildx build --platform linux/arm64,linux/amd64 -t oab-toolchain images/toolchain
```

## Smoke test

```sh
docker run --rm oab-toolchain bash -lc 'python3 --version && node --version && git --version && gh --version && test "$(id -u)" = "1000" && echo non-root-ok && test -w /var/log/oab-jobs && echo jobs-dir-ok'
```

Expected: version lines, `non-root-ok`, `jobs-dir-ok`. (Network isolation — `oab-sandbox` bridge unreachable from host/tailnet — is verified by the adapter acceptance suite, not this image-level smoke test.)

## Extending

Coding CLIs (codex, etc.) land in follow-up layers or sibling images — keep this base small and cache-friendly. Add heavyweight tools as separate images sharing this base (`FROM oab-toolchain`).
