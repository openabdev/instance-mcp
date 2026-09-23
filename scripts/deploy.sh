#!/bin/bash
# Deploy oab-instance-mcp on this Mac (run ON the target, e.g. macmini).
#   scripts/deploy.sh <allow-login-email> [signing-identity-hash]
# - wraps the release binary in a minimal .app so TCC grants bind to a stable bundle id
# - signs it (Apple Development is enough for a local LaunchAgent; no notarization needed)
# - installs a LaunchAgent in gui/<uid> and `tailscale serve --https=8444`
set -euo pipefail
LOGIN="${1:?usage: deploy.sh <allow-login-email> [identity]}"
IDENTITY="${2:-<codesign-identity>}"   # Apple Development, team <team-id>
PORT=8795; HTTPS_PORT=8444
LABEL=dev.openab.instance-mcp
BUNDLE_ID=dev.openab.instance-mcp
BASE="$HOME/.local/oab-instance-mcp"
APP="$BASE/oab-instance-mcp.app"
BIN="$(cd "$(dirname "$0")/.." && pwd)/.build/release/oab-instance-mcp"
TS=/Applications/Tailscale.app/Contents/MacOS/Tailscale
VERSION="$("$BIN" --version)"
DNSNAME="$("$TS" status --self --peers=false --json 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))')"

[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }
NEWEST_SRC=$(find "$(dirname "$0")/../Sources" -name '*.swift' -newer "$BIN" | head -1)
[ -z "$NEWEST_SRC" ] || { echo "binary older than $NEWEST_SRC — rebuild first"; exit 1; }
mkdir -p "$BASE" "$HOME/Library/Logs/oab-instance-mcp"

# One-shot migration from the pre-0.4.0 name (oab-mac-agent / oab-mc-agent /
# dev.openab.mac-agent): retire the old LaunchAgent and carry the bearer token over so
# clients keep working. TCC grants do NOT carry over — they are keyed on the bundle id.
OLD_LABEL=dev.openab.mac-agent
if launchctl print "gui/$(id -u)/$OLD_LABEL" >/dev/null 2>&1; then
  echo "retiring old LaunchAgent $OLD_LABEL"
  launchctl bootout "gui/$(id -u)/$OLD_LABEL" || true
  for _ in $(seq 1 40); do launchctl print "gui/$(id -u)/$OLD_LABEL" >/dev/null 2>&1 || break; sleep 0.25; done
fi
rm -f "$HOME/Library/LaunchAgents/$OLD_LABEL.plist"
if [ -s "$HOME/.config/oab-mac-agent/token" ] && [ ! -s "$HOME/.config/oab-instance-mcp/token" ]; then
  mkdir -p "$HOME/.config/oab-instance-mcp"
  mv "$HOME/.config/oab-mac-agent/token" "$HOME/.config/oab-instance-mcp/token"
  echo "carried bearer token over from ~/.config/oab-mac-agent/token"
fi

# Bearer token: a second factor AND-combined with --allow-login, so a leaked tailnet
# credential alone cannot reach the agent. Generated once and reused across re-deploys
# (stable like the TCC grants); rotate by deleting the file and re-deploying.
TOKEN_FILE="$HOME/.config/oab-instance-mcp/token"
if [ ! -s "$TOKEN_FILE" ]; then
  mkdir -p "$(dirname "$TOKEN_FILE")"
  ( umask 077; openssl rand -hex 32 > "$TOKEN_FILE" )
  chmod 600 "$TOKEN_FILE"
  echo "generated new bearer token at $TOKEN_FILE"
else
  echo "reusing existing bearer token at $TOKEN_FILE"
fi

echo "--- bundle $APP ($VERSION) ---"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/oab-instance-mcp"
cat >"$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>oab-instance-mcp</string>
  <key>CFBundleExecutable</key><string>oab-instance-mcp</string>
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
    <string>$APP/Contents/MacOS/oab-instance-mcp</string>
    <string>--port</string><string>$PORT</string>
    <string>--allow-login</string><string>$LOGIN</string>
    <string>--token-file</string><string>$TOKEN_FILE</string>
    <string>--menu-bar</string>
    <string>--public-url</string><string>https://$DNSNAME:$HTTPS_PORT/mcp</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/oab-instance-mcp/agent.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/oab-instance-mcp/agent.log</string>
</dict></plist>
EOF
plutil -lint "$PLIST"
UID_=$(id -u)
if launchctl print "gui/$UID_/$LABEL" >/dev/null 2>&1; then
  launchctl bootout "gui/$UID_/$LABEL" || true
  # bootout returns before the job is gone; bootstrap races it and fails with EEXIST.
  for _ in $(seq 1 40); do launchctl print "gui/$UID_/$LABEL" >/dev/null 2>&1 || break; sleep 0.25; done
fi
launchctl bootstrap "gui/$UID_" "$PLIST"
for _ in $(seq 1 20); do curl -s -m 1 "http://127.0.0.1:$PORT/healthz" >/dev/null && break; sleep 0.25; done
launchctl print "gui/$UID_/$LABEL" | grep -E 'state|pid ='
tail -3 "$HOME/Library/Logs/oab-instance-mcp/agent.log"

echo "--- tailscale serve :$HTTPS_PORT → :$PORT ---"
"$TS" serve --bg --https="$HTTPS_PORT" "http://127.0.0.1:$PORT" >/dev/null
"$TS" serve status | grep -A1 ":$HTTPS_PORT"

echo
echo "MCP URL: https://$DNSNAME:$HTTPS_PORT/mcp"
echo "Bearer token (set this in the client too): $(cat "$TOKEN_FILE")"
echo "Screen Recording: System Settings → Privacy & Security → Screen & System Audio Recording → enable oab-instance-mcp, then: launchctl kickstart -k gui/$UID_/$LABEL"
