#!/bin/sh
# get.sh - download a hprt-ble-bridge release, optionally wipe old bridges, install one or more printers
# usage:  curl -fsSL https://raw.githubusercontent.com/OWNER/REPO/main/get.sh | sh
#         curl -fsSL …/get.sh | sh -s -- v1.4.0        (a set version)
set -eu

REPO="crisp20/hprt-ble-bridge"
TAG="${1:-latest}"
BASE="$HOME/Library/Application Support/hprt-ble-bridge"
TTY=/dev/tty                                       # stdin is the script itself under curl | sh

ask() {  # ask "question" default → echoes answer
  printf '%s ' "$1" > "$TTY"; read -r a < "$TTY" || a=""; echo "${a:-$2}"
}

# --- 1. resolve and download the release zip -------------------------------------------
if [ "$TAG" = latest ]; then
  TAG=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1)
  [ -n "$TAG" ] || { echo "could not find the latest release of $REPO" >&2; exit 1; }
fi
DEST="$BASE/$TAG"
TMPZIP=$(mktemp -t hprt-ble-bridge).zip
echo "== downloading $REPO $TAG"
curl -fSL --progress-bar -o "$TMPZIP" "https://github.com/$REPO/archive/refs/tags/$TAG.zip"

# --- 2. unzip (GitHub wraps the source in REPO-TAG/) -------------------------------------
rm -rf "$DEST"; mkdir -p "$DEST"
unzip -q "$TMPZIP" -d "$DEST.tmp"; rm -f "$TMPZIP"
mv "$DEST.tmp"/*/* "$DEST"/; rm -rf "$DEST.tmp"
cd "$DEST"
echo "   unpacked to $DEST"

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
