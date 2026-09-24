#!/bin/bash
# Install the Playwright MCP LaunchAgent beside oab-instance-mcp (run ON the target Mac).
# Renders the plist with this user's $HOME (launchd does not expand ~), installs the
# wrapper, pins @playwright/mcp, and exposes it via `tailscale serve --https=8443`.
set -euo pipefail
LABEL=dev.openab.instance-mcp.pw-mcp
BASE="$HOME/.local/oab-instance-mcp"
LOGS="$HOME/Library/Logs/oab-instance-mcp"
HERE="$(cd "$(dirname "$0")" && pwd)"
TS=/Applications/Tailscale.app/Contents/MacOS/Tailscale

mkdir -p "$BASE/pw-mcp" "$LOGS"
cp "$HERE/pw-mcp.sh" "$BASE/pw-mcp.sh"; chmod +x "$BASE/pw-mcp.sh"
[ -x "$BASE/pw-mcp/node_modules/.bin/playwright-mcp" ] || \
  (cd "$BASE/pw-mcp" && npm install --save-exact @playwright/mcp@0.0.82 && npx playwright install chromium)

PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$BASE/pw-mcp.sh</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$LOGS/pw-mcp.log</string>
  <key>StandardErrorPath</key><string>$LOGS/pw-mcp.err</string>
</dict></plist>
EOF
plutil -lint "$PLIST"
UID_=$(id -u)
launchctl bootout "gui/$UID_/$LABEL" 2>/dev/null || true
for _ in $(seq 1 40); do launchctl print "gui/$UID_/$LABEL" >/dev/null 2>&1 || break; sleep 0.25; done
launchctl bootstrap "gui/$UID_" "$PLIST"
"$TS" serve --bg --https=8443 http://127.0.0.1:8794 >/dev/null
launchctl print "gui/$UID_/$LABEL" | grep -E 'state|pid ='
echo "MCP URL: https://$("$TS" status --self --peers=false --json | python3 -c 'import json,sys;print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))'):8443/mcp"
