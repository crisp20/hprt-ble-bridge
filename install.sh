#!/bin/bash
# Usage: sh install.sh XXXX [PORT]     e.g.  sh install.sh B3F8 9100 ; sh install.sh 5676 9101
set -euo pipefail

ARG="${1:?usage: $0 XXXX|D35BT-XXXX [PORT]   (last 4 hex of BT_MAC on the self-test label)}"
ARG="$(printf '%s' "$ARG" | tr '[:lower:]' '[:upper:]')"
case "$ARG" in D35BT-*) NAME="$ARG" ;; *) NAME="D35BT-$ARG" ;; esac
SUFFIX="${NAME#D35BT-}"
PORT="${2:-9100}"

QUEUE="HPRT_D35BT_$SUFFIX"
LABEL="local.hprt-ble-bridge.$SUFFIX"
BIN="$HOME/bin/hprt-ble-bridge"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="/tmp/hprt-ble-bridge-$SUFFIX.log"
SRC="$(cd "$(dirname "$0")" && pwd)"
echo "Printer: $NAME   port: $PORT   queue: $QUEUE"

grep -q 'HPRT_PORT' "$SRC/main.swift" || { echo "main.swift lacks HPRT_PORT support"; exit 1; }

echo "== 1/4 build bridge"
mkdir -p "$HOME/bin" "$HOME/Library/LaunchAgents"
swiftc -O "$SRC/main.swift" -o "$BIN" \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$SRC/Info.plist"

echo "== 2/4 Bluetooth check (one blank label feeds)"
# Refuse a port that's held by anything other than THIS printer's own bridge, before touching anything
OWNPID="$(launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | awk '/^\tpid = / {print $3}' || true)"
HOLDERS="$(lsof -nP -t -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | grep -vx "${OWNPID:-none}" || true)"
if [ -n "$HOLDERS" ]; then
  echo "Port $PORT is already used by another bridge/process:"; lsof -nP -iTCP:"$PORT" -sTCP:LISTEN
  echo "Pick another port, e.g. $((PORT+1))."; exit 1
fi
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
sleep 1
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "Port $PORT is already used by another bridge/process:"; lsof -nP -iTCP:"$PORT" -sTCP:LISTEN
  echo "Pick another port, e.g. $((PORT+1))."; exit 1
fi
printf '! 0 200 200 80 1\r\nFORM\r\nPRINT\r\n' > /tmp/hprt-probe.cpcl
HPRT_NAME="$NAME" HPRT_FLOW=delay "$BIN" send /tmp/hprt-probe.cpcl || {
  echo "Probe failed: check the name, power-cycle the printer, close phone apps, re-run."; exit 1; }

echo "== 3/4 LaunchAgent $LABEL"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$BIN</string><string>serve</string></array>
  <key>EnvironmentVariables</key><dict>
    <key>HPRT_NAME</key><string>$NAME</string>
    <key>HPRT_PORT</key><string>$PORT</string>
    <key>HPRT_FLOW</key><string>credit</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict></plist>
EOF
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "== 4/4 CUPS queue $QUEUE"
MODEL="$(lpinfo -m | grep -i 'd35bt' | head -1 | cut -d' ' -f1)"
[ -n "$MODEL" ] || { echo "HPRT D35BT driver not found: install it from download.hprt.com"; exit 1; }
sudo lpadmin -p "$QUEUE" -D "HPRT D35BT $SUFFIX (Bluetooth)" \
  -v "socket://127.0.0.1:$PORT" -m "$MODEL" -o PageSize=Custom.60x40mm -E
sudo cupsenable "$QUEUE"; sudo cupsaccept "$QUEUE"

sleep 2; tail -2 "$LOG"
echo "Done. Print to 'HPRT D35BT $SUFFIX (Bluetooth)'."
