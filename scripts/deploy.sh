#!/bin/bash
# Deploy oab-mc-agent on this Mac (run ON the target, e.g. macmini).
#   scripts/deploy.sh <allow-login-email> [signing-identity-hash]
# - wraps the release binary in a minimal .app so TCC grants bind to a stable bundle id
# - signs it (Apple Development is enough for a local LaunchAgent; no notarization needed)
# - installs a LaunchAgent in gui/<uid> and `tailscale serve --https=8444`
set -euo pipefail
LOGIN="${1:?usage: deploy.sh <allow-login-email> [identity]}"
IDENTITY="${2:-<codesign-identity>}"   # Apple Development, team <team-id>
PORT=8795; HTTPS_PORT=8444
LABEL=dev.openab.mac-agent
BUNDLE_ID=dev.openab.mac-agent
BASE="$HOME/.local/oab-mac-agent"
APP="$BASE/oab-mc-agent.app"
BIN="$(cd "$(dirname "$0")/.." && pwd)/.build/release/oab-mc-agent"
TS=/Applications/Tailscale.app/Contents/MacOS/Tailscale
VERSION="$("$BIN" --version)"

[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }
mkdir -p "$BASE" "$HOME/Library/Logs/oab-mac-agent"

echo "--- bundle $APP ($VERSION) ---"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/oab-mc-agent"
cat >"$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>oab-mc-agent</string>
  <key>CFBundleExecutable</key><string>oab-mc-agent</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>OpenAB</string>
</dict></plist>
EOF
# The <team-id> dev identity lives in a dedicated keychain whose password is on
# disk (see ~/.config/signing/README.md). The login keychain
# refuses codesign over non-interactive SSH (errSecInternalComponent).
KEYCHAIN="$HOME/Library/Keychains/signing.keychain-db"
security unlock-keychain -p "$(cat "$HOME/.config/signing/keychain-password")" "$KEYCHAIN"
codesign --force --options runtime --timestamp=none --keychain "$KEYCHAIN" --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
codesign --verify --deep --strict "$APP" && echo "signed: $(codesign -dv "$APP" 2>&1 | grep -E '^(Authority=Apple Dev|TeamIdentifier)' | tr '\n' ' ')"

echo "--- LaunchAgent $LABEL ---"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>$APP/Contents/MacOS/oab-mc-agent</string>
    <string>--port</string><string>$PORT</string>
    <string>--allow-login</string><string>$LOGIN</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/oab-mac-agent/agent.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/oab-mac-agent/agent.log</string>
</dict></plist>
EOF
plutil -lint "$PLIST"
UID_=$(id -u)
launchctl bootout "gui/$UID_/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID_" "$PLIST"
for _ in $(seq 1 20); do curl -s -m 1 "http://127.0.0.1:$PORT/healthz" >/dev/null && break; sleep 0.25; done
launchctl print "gui/$UID_/$LABEL" | grep -E 'state|pid ='
tail -3 "$HOME/Library/Logs/oab-mac-agent/agent.log"

echo "--- tailscale serve :$HTTPS_PORT → :$PORT ---"
"$TS" serve --bg --https="$HTTPS_PORT" "http://127.0.0.1:$PORT" >/dev/null
"$TS" serve status | grep -A1 ":$HTTPS_PORT"

echo
echo "MCP URL: https://$("$TS" status --self --peers=false --json 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))'):$HTTPS_PORT/mcp"
echo "Screen Recording: System Settings → Privacy & Security → Screen & System Audio Recording → enable oab-mc-agent, then: launchctl kickstart -k gui/$UID_/$LABEL"
