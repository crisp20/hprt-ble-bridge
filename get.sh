#!/bin/sh
# get.sh - download a hprt-ble-bridge release, optionally wipe old bridges, install one or more printers
# usage:  curl -fsSL https://raw.githubusercontent.com/crisp20/hprt-ble-bridge/main/get.sh | sh
#         curl -fsSL …/get.sh | sh -s -- v1.4.0        (a set version)
set -eu

REPO="crisp20/hprt-ble-bridge"
TAG="${1:-latest}"
TTY=/dev/tty                                       # stdin is the script itself under curl | sh

ask() {  # ask "question" default → echoes answer
  printf '%s ' "$1" > "$TTY"; read -r a < "$TTY" || a=""; echo "${a:-$2}"
}

# --- 1. resolve the release tag -----------------------------------------------------------
if [ "$TAG" = latest ]; then
  TAG=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1)
  [ -n "$TAG" ] || { echo "could not find the latest release of $REPO" >&2; exit 1; }
fi

# --- 2. download + unzip into a private temp folder, removed when this script exits ------
WORK=$(mktemp -d "/tmp/hprt-ble-bridge.XXXXXX")
trap 'cd /; rm -rf "$WORK"' EXIT                   # success, error (set -e) or Ctrl-C
trap 'exit 130' INT TERM                           # make Ctrl-C go through the EXIT trap

echo "== downloading $REPO $TAG"
curl -fsSL -o "$WORK/src.zip" "https://github.com/$REPO/archive/refs/tags/$TAG.zip"
echo "   $(( $(wc -c < "$WORK/src.zip") / 1024 )) KB"
unzip -q "$WORK/src.zip" -d "$WORK"
SRC=$(find "$WORK" -mindepth 1 -maxdepth 1 -type d | head -n 1)   # GitHub wraps it in REPO-TAG/
[ -n "$SRC" ] && [ -f "$SRC/install.sh" ] || { echo "unexpected zip layout in $TAG" >&2; exit 1; }
cd "$SRC"

# --- 3. optional fresh start --------------------------------------------------------------
if ls "$HOME"/Library/LaunchAgents/local.hprt-ble-bridge.*.plist >/dev/null 2>&1; then
  echo "== bridges already installed:"; ls "$HOME"/Library/LaunchAgents/local.hprt-ble-bridge.*.plist | sed 's/.*bridge\./   /; s/\.plist//'
  case $(ask "Uninstall all of them first (fresh start)? [y/N]" n) in
    [yY]*) sh ./uninstall.sh --all < "$TTY" ;;
  esac
fi

# --- 4. install one or more printers -----------------------------------------------------
while :; do
  sh ./install.sh < "$TTY"            # install.sh asks for printer and port itself
  case $(ask "Install another printer on this Mac? [y/N]" n) in [yY]*) ;; *) break ;; esac
done
echo "== done. Logs: ~/Library/Logs/hprt-ble-bridge-*.log"
