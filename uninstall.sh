#!/usr/bin/env bash
set -euo pipefail

DEST="$HOME/.local/share/pr-merge-notify"
UNIT_DIR="$HOME/.config/systemd/user"

systemctl --user disable --now pr-merge-notify.timer 2>/dev/null || true
rm -f "$UNIT_DIR/pr-merge-notify.service" "$UNIT_DIR/pr-merge-notify.timer"
systemctl --user daemon-reload

if [[ ${1:-} == "--purge" ]]; then
  rm -rf "$DEST"
  echo "Removed units and $DEST"
else
  echo "Removed units. Config and state kept in $DEST (use --purge to delete)."
fi
