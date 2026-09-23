#!/bin/zsh
# Playwright MCP for oab-instance-mcp step-1 PoC. Loopback only; exposed via tailscale serve.
export PATH=/opt/homebrew/bin:/usr/bin:/bin
cd /Users/<you>/.local/oab-instance-mcp/pw-mcp
exec ./node_modules/.bin/playwright-mcp \
  --host 127.0.0.1 --port 8794 \
  --allowed-hosts macmini.<tailnet>.ts.net,macmini.<tailnet>.ts.net:8443,127.0.0.1,localhost \
  --user-data-dir /Users/<you>/.local/oab-instance-mcp/pw-profile \
  --output-dir /Users/<you>/.local/oab-instance-mcp/pw-output \
  --idle-timeout 1800000 \
  --browser chromium --shared-browser-context --caps vision,pdf
