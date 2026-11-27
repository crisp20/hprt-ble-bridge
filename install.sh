#!/bin/bash
# Install the Bluetooth bridge for one HPRT D35BT printer for the CURRENT macOS user.
# Usage:  sh install.sh [XXXX [PORT]]    e.g.  sh install.sh B3F8 9100 ; sh install.sh  (asks)
#   XXXX = last 4 hex digits of BT_MAC on the printer's self-test label (or the full D35BT-XXXX name)
# Run as a normal user (no sudo). An admin dialog appears only if the shared CUPS queue must be created.
# Every account that prints on this Mac runs this once. Works on macOS 10.12+ (bash 3.2).
set -euo pipefail

PB=/usr/libexec/PlistBuddy
AGENTS="$HOME/Library/LaunchAgents"
TTY=/dev/tty
has_tty() { { : < "$TTY"; } 2>/dev/null; }                       # really openable, not just -r
ask()     { printf '%s ' "$1" > "$TTY"; a=""; read -r a < "$TTY" || true; echo "${a:-$2}"; }
port_of() { "$PB" -c 'Print :EnvironmentVariables:HPRT_PORT' "$1" 2>/dev/null || true; }

# ---- printer: from argument, or ask ----
SUFFIX="${1:-}"
if [ -z "$SUFFIX" ]; then
  has_tty || { echo "usage: sh install.sh XXXX [PORT]   (XXXX = last 4 of the printer name)" >&2; exit 2; }
  echo "Printer name is on the printer's label / self-test page, e.g. D35BT-91DE → 91DE"
  SUFFIX="$(ask "Printer (last 4 characters):" "")"
fi
SUFFIX="$(printf '%s' "$SUFFIX" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]' | sed 's/^D35BT-//')"
case "$SUFFIX" in
  [0-9A-F][0-9A-F][0-9A-F][0-9A-F]) ;;
  *) echo "invalid printer '$SUFFIX' (expected 4 hex characters, e.g. 91DE)" >&2; exit 2 ;;
esac

NAME="D35BT-$SUFFIX"                       # HPRT_NAME is case-sensitive: always upper case
LABEL="local.hprt-ble-bridge.$SUFFIX"
PLIST="$AGENTS/$LABEL.plist"

# ---- port: from argument, or suggest (this printer's old port, else the first free 9100+) ----
own=""
if [ -f "$PLIST" ]; then own="$(port_of "$PLIST")"; fi
used=" "
for p in "$AGENTS"/local.hprt-ble-bridge.*.plist; do       # loop, not cat|grep: no pipefail trap
  [ -e "$p" ] && [ "$p" != "$PLIST" ] || continue
  used="$used$(port_of "$p") "
done
suggest="${own:-9100}"
if [ -z "$own" ]; then
  while case "$used" in *" $suggest "*) true ;; *) false ;; esac; do suggest=$((suggest + 1)); done
fi

PORT="${2:-}"
if [ -z "$PORT" ]; then
  if has_tty; then PORT="$(ask "Port [$suggest]:" "$suggest")"; else PORT="$suggest"; fi
fi
case "$PORT" in ""|*[!0-9]*) echo "invalid port '$PORT'" >&2; exit 2 ;; esac

UIDN="$(id -u)"
QUEUE="HPRT_D35BT_$SUFFIX"
BIN="$HOME/bin/hprt-ble-bridge"
LOGDIR="$HOME/Library/Logs"
LOG="$LOGDIR/hprt-ble-bridge-$SUFFIX.log"
SRC="$(cd "$(dirname "$0")" && pwd)"
echo "Printer: $NAME   port: $PORT   queue: $QUEUE   user: $(id -un)"

# ---- 0. preflight ----
[ "$UIDN" -ne 0 ] || { echo "Do not run with sudo/as root: the bridge must belong to the logged-in user."; exit 1; }
command -v swiftc >/dev/null 2>&1 || { echo "swiftc not found: install Command Line Tools (xcode-select --install)"; exit 1; }
[ -f "$SRC/main.swift" ] && [ -f "$SRC/Info.plist" ] || { echo "main.swift / Info.plist not found in $SRC"; exit 1; }
grep -q 'HPRT_PORT' "$SRC/main.swift" || { echo "main.swift lacks HPRT_PORT support"; exit 1; }

# Another printer's agent of THIS user configured for the same port (even if it is not running right now)?
for p in "$AGENTS"/local.hprt-ble-bridge.*.plist; do
  [ -e "$p" ] || continue
  [ "$p" = "$PLIST" ] && continue
  other="$("$PB" -c 'Print :EnvironmentVariables:HPRT_PORT' "$p" 2>/dev/null || true)"
  if [ "$other" = "$PORT" ]; then
    echo "Port $PORT is already assigned to $(basename "$p" .plist). Pick another port, e.g. $((PORT+1))."; exit 1
  fi
done

# Port held by anything other than THIS printer's own running bridge? Checked before touching anything.
OWNPID="$(launchctl print "gui/$UIDN/$LABEL" 2>/dev/null | awk '/^\tpid = / {print $3}' || true)"
HOLDERS="$(lsof -nP -t -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | grep -vx "${OWNPID:-none}" || true)"
if [ -n "$HOLDERS" ]; then
  echo "Port $PORT is already in use:"; lsof -nP -iTCP:"$PORT" -sTCP:LISTEN || true
  echo "If another account is logged in on this Mac, its bridge may hold the port: log it out, or pick another port."
  exit 1
fi

echo "== 1/4 build bridge"
mkdir -p "$HOME/bin" "$AGENTS" "$LOGDIR"
swiftc -O "$SRC/main.swift" -o "$BIN.new" -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$SRC/Info.plist"
mv -f "$BIN.new" "$BIN"                      # atomic swap: running bridges keep the old copy until restarted

echo "== 2/4 Bluetooth check (one blank label feeds)"
launchctl bootout "gui/$UIDN/$LABEL" 2>/dev/null || true
sleep 1
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "Port $PORT is still in use:"; lsof -nP -iTCP:"$PORT" -sTCP:LISTEN || true; exit 1
fi
PROBE="$(mktemp -t hprt-probe)"
trap 'rm -f "$PROBE"' EXIT
printf '! 0 200 200 80 1\r\nFORM\r\nPRINT\r\n' > "$PROBE"
echo "(macOS 10.15+: allow Bluetooth if asked)"
HPRT_NAME="$NAME" HPRT_FLOW=delay "$BIN" send "$PROBE" || { echo "Probe failed: check the name, power-cycle the printer, close phone apps / other Bluetooth tabs, re-run."; exit 1; }

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
    <key>HPRT_KEEPALIVE_MS</key><string>30000</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict></plist>
EOF
launchctl bootstrap "gui/$UIDN" "$PLIST"

echo "== 4/4 CUPS queue $QUEUE (shared by all accounts)"
if lpstat -v "$QUEUE" 2>/dev/null | grep -q "socket://127.0.0.1:$PORT/?snmp=false\$"; then
  echo "queue already set up"
else
  MODEL="$(lpinfo -m | grep -i 'd35bt' | head -1 | cut -d' ' -f1)"
  [ -n "$MODEL" ] || { echo "HPRT D35BT driver not found: an admin must install it from download.hprt.com"; exit 1; }
  CMD="/usr/sbin/lpadmin -p '$QUEUE' -D 'HPRT D35BT $SUFFIX (Bluetooth)' -v 'socket://127.0.0.1:$PORT/?snmp=false' -m '$MODEL' -o PageSize=Custom.60x40mm -E && /usr/sbin/cupsenable '$QUEUE' && /usr/sbin/cupsaccept '$QUEUE'"
  echo "Asking for an administrator to create the shared print queue…"
  osascript -e "do shell script \"$CMD\" with administrator privileges" >/dev/null || {
    echo "Admin step cancelled or failed: the bridge is installed, but the queue is not."
    echo "Re-run this script and enter an administrator's name and password."; exit 1; }
  echo "queue created"
fi

# Restart this user's other bridges so they run the freshly built binary (do not run during a print job)
for p in "$AGENTS"/local.hprt-ble-bridge.*.plist; do
  [ -e "$p" ] || continue
  l="$(basename "$p" .plist)"; [ "$l" = "$LABEL" ] && continue
  launchctl kickstart -k "gui/$UIDN/$l" 2>/dev/null || true
done

sleep 2; tail -2 "$LOG" 2>/dev/null || true
echo "Done. Print to 'HPRT D35BT $SUFFIX (Bluetooth)'."
echo "Create the 60 x 40 mm paper size (margins 0) and save print settings for this printer."
