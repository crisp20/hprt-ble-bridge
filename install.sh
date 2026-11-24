#!/bin/bash
# Usage: ./install.sh D35BT-XXXX
set -euo pipefail

ARG="${1:?usage: $0 D35BT-XXXX  (or just XXXX = last 4 hex of BT_MAC on the self-test label)}"
ARG="$(printf '%s' "$ARG" | tr '[:lower:]' '[:upper:]')"
case "$ARG" in D35BT-*) NAME="$ARG" ;; *) NAME="D35BT-$ARG" ;; esac
echo "Printer BLE name: $NAME"
QUEUE="HPRT_D35BT_BT"
LABEL="local.$(id -un).hprt-ble-bridge"
BIN="$HOME/bin/hprt-ble-bridge"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SRC="$(cd "$(dirname "$0")" && pwd)"
echo "== 1/4 build bridge"
mkdir -p "$HOME/bin" "$HOME/Library/LaunchAgents"
swiftc -O "$SRC/main.swift" -o "$BIN" \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$SRC/Info.plist"

echo "== 2/4 one-off Bluetooth permission check (allow the prompt for Terminal)"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true   # an existing bridge would hold the printer's only BLE slot
printf '! 0 200 200 80 1\r\nFORM\r\nPRINT\r\n' > /tmp/hprt-probe.cpcl
HPRT_NAME="$NAME" HPRT_FLOW=delay "$BIN" send /tmp/hprt-probe.cpcl || {
  echo "Probe failed: power-cycle the printer, close phone apps, re-run."; exit 1; }

echo "== 3/4 LaunchAgent"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$BIN</string><string>serve</string></array>
  <key>EnvironmentVariables</key><dict>
    <key>HPRT_NAME</key><string>$NAME</string>
    <key>HPRT_FLOW</key><string>credit</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>/tmp/hprt-ble-bridge.log</string>
</dict></plist>
EOF
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "== 4/4 CUPS queue"
MODEL="$(lpinfo -m | grep -i 'd35bt' | head -1 | cut -d' ' -f1)"
[ -n "$MODEL" ] || { echo "HPRT D35BT driver not found: install it from download.hprt.com"; exit 1; }
sudo lpadmin -p "$QUEUE" -D "HPRT D35BT (Bluetooth)" \
  -v socket://127.0.0.1:9100 -m "$MODEL" -o PageSize=Custom.60x40mm -E
sudo cupsenable "$QUEUE"; sudo cupsaccept "$QUEUE"

sleep 2; tail -2 /tmp/hprt-ble-bridge.log
echo "Done. Print from any app to 'HPRT D35BT (Bluetooth)'."
