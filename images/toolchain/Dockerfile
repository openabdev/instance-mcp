# oab-toolchain — the sandbox image for the sandbox adapter (docs/adr/sandbox-adapter.md)
#
# Contains the fat toolchain that stays OUT of agent images: python, node,
# git, gh. Sandboxes are created from this image by the OrbStack adapter
# (Phase 1) via:
#
#   docker run -d --network oab-sandbox --cpus <n> --memory <m> \
#     --pids-limit <p> --security-opt no-new-privileges \
#     oab-toolchain sleep infinity
#
# Build (multi-arch; arm64 first-class — Mac mini / Pi, amd64 for Intel nodes):
#
#   docker buildx build --platform linux/arm64,linux/amd64 -t oab-toolchain images/toolchain
#
# Conventions required by the adapter contract:
# - /var/log/oab-jobs/    exec_start output files (<job_id>.out / .err)
# - /workspace            default cwd for sandbox_exec
# - non-root user `sandbox` (uid 1000); no sudo, no setuid helpers
# - NO credentials baked in: tokens are injected per-session via
#   sandbox_exec env (see ADR "State of record" / auth notes)

FROM debian:bookworm-slim

LABEL org.opencontainers.image.source="https://github.com/openabdev/instance-mcp" \
      org.opencontainers.image.title="oab-toolchain" \
      org.opencontainers.image.description="Sandbox toolchain image for the sandbox adapter (docs/adr/sandbox-adapter.md)" \
      org.opencontainers.image.base.name="docker.io/library/debian:bookworm-slim"

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    PIP_NO_CACHE_DIR=1

# Base toolchain: python, node (NodeSource, keyring-verified apt source —
# no pipe-to-bash), git, gh, and the small utilities coding agents
# habitually need. One layer, cleaned.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg \
    && mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
         | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" \
         > /etc/apt/sources.list.d/nodesource.list \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
         -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
         > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends \
        nodejs \
        gh \
        python3 python3-pip python3-venv \
        git \
        jq ripgrep unzip zip less procps \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Non-root sandbox user; job-output dir owned by it (adapter contract path).
RUN useradd -m -u 1000 -s /bin/bash sandbox \
    && mkdir -p /var/log/oab-jobs /workspace \
    && chown sandbox:sandbox /var/log/oab-jobs /workspace

USER sandbox
WORKDIR /workspace

# The adapter starts sandboxes with an explicit `sleep infinity`; CMD is a
# fallback for manual `docker run`.
CMD ["sleep", "infinity"]
