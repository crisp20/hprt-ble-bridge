#!/bin/bash
# Remove HPRT D35BT Bluetooth bridge(s) for the CURRENT macOS user.
# Usage:
#   sh uninstall.sh XXXX            this user's bridge for one printer (shared queue is kept)
#   sh uninstall.sh XXXX --queue    ...and delete that printer's shared CUPS queue (admin dialog, affects ALL accounts)
#   sh uninstall.sh --all           all of this user's bridges + binary + logs + Bluetooth permission
#   sh uninstall.sh --all --queue   ...and delete every Bluetooth-bridge queue (socket://127.0.0.1:*; USB queues are kept)
set -euo pipefail

TARGET="${1:?usage: $0 XXXX|--all [--queue]}"
WITHQ=no
case "${2:-}" in --queue) WITHQ=yes ;; "") ;; *) echo "unknown option: $2"; exit 1 ;; esac

UIDN="$(id -u)"
AGENTS="$HOME/Library/LaunchAgents"
LOGDIR="$HOME/Library/Logs"
PB=/usr/libexec/PlistBuddy
[ "$UIDN" -ne 0 ] || { echo "Do not run with sudo/as root: run it as the user whose bridge you remove."; exit 1; }

remove_agent() {                                  # $1 = plist path
  local plist="$1" label port
  label="$(basename "$plist" .plist)"
  port="$("$PB" -c 'Print :EnvironmentVariables:HPRT_PORT' "$plist" 2>/dev/null || true)"
  launchctl bootout "gui/$UIDN/$label" 2>/dev/null || true
  rm -f "$plist" "$LOGDIR/hprt-ble-bridge-${label##*.}.log"
  [ -n "$port" ] && rm -f "$LOGDIR/hprt-last-job-$port.bin"
  echo "removed bridge $label${port:+ (port $port)}"
}

if [ "$TARGET" = "--all" ]; then
  for p in "$AGENTS"/local*hprt-ble-bridge*.plist; do  # also catches the old local.justin.hprt-ble-bridge
    [ -e "$p" ] || continue
    remove_agent "$p"
  done
  rm -f "$HOME/bin/hprt-ble-bridge" "$HOME/bin/hprt-ble-bridge.new"
  rm -f "$LOGDIR"/hprt-ble-bridge-*.log "$LOGDIR"/hprt-last-job-*.bin
  rm -f /tmp/hprt-ble-bridge*.log /tmp/hprt-last-job*.bin /tmp/hprt-probe.cpcl 2>/dev/null || true  # old locations
  tccutil reset BluetoothAlways local.hprt-ble-bridge >/dev/null 2>&1 || true                        # 10.15+ only
  echo "removed binary, logs and Bluetooth permission for $(id -un)"
  QLIST="$(lpstat -v 2>/dev/null | awk '/socket:\/\/127\.0\.0\.1:/ { n=$3; sub(":$", "", n); print n }' || true)"
else
  ARG="$(printf '%s' "$TARGET" | tr '[:lower:]' '[:upper:]')"
  SUFFIX="${ARG#D35BT-}"
  PLIST="$AGENTS/local.hprt-ble-bridge.$SUFFIX.plist"
  if [ -e "$PLIST" ]; then remove_agent "$PLIST"; else echo "no bridge for $SUFFIX in this account"; fi
  # this printer's queue, plus any extra size queues such as HPRT_D35BT_B3F8_54x70
  QLIST="$(lpstat -v 2>/dev/null | awk -v q="HPRT_D35BT_$SUFFIX" \
    '/socket:\/\/127\.0\.0\.1:/ { n=$3; sub(":$", "", n); if (n == q || index(n, q "_") == 1) print n }' || true)"
fi

if [ -z "$QLIST" ]; then
  echo "no Bluetooth-bridge queues found"
elif [ "$WITHQ" = yes ]; then
  CMD=""
  for q in $QLIST; do CMD="$CMD/usr/sbin/lpadmin -x '$q'; "; done
  echo "Deleting shared queue(s) for ALL accounts on this Mac:" $QLIST
  osascript -e "do shell script \"$CMD\" with administrator privileges" >/dev/null || {
    echo "Admin step cancelled or failed: queues kept."; exit 1; }
  echo "queues deleted"
else
  echo "Kept shared queue(s) (other accounts may use them):" $QLIST
  echo "Re-run with --queue to delete them."
fi
echo "Done."
