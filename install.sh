#!/usr/bin/env bash
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HOME/.local/share/pr-merge-notify"
UNIT_DIR="$HOME/.config/systemd/user"
ENV_FILE="$DEST/config/pr-merge-notify.env"

for cmd in gh jq curl systemctl; do
  command -v "$cmd" >/dev/null || { echo "Missing dependency: $cmd" >&2; exit 1; }
done

mkdir -p "$DEST/bin" "$DEST/config" "$DEST/state" "$UNIT_DIR"

if [[ $SRC != "$DEST" ]]; then
  install -m 755 "$SRC/bin/pr-merge-notify.sh" "$DEST/bin/pr-merge-notify.sh"
  install -m 644 "$SRC/config/pr-merge-notify.env.example" "$DEST/config/pr-merge-notify.env.example"
fi

# --- configuration -----------------------------------------------------------
needs_config() {
  [[ ! -f $ENV_FILE ]] || grep -qE 'XXXX|your-github-username' "$ENV_FILE"
}

if needs_config; then
  if [[ ! -t 0 ]]; then
    install -m 600 "$DEST/config/pr-merge-notify.env.example" "$ENV_FILE"
    echo "Not a terminal. Edit $ENV_FILE and re-run ./install.sh" >&2
    exit 1
  fi

  default_user=$(gh api user --jq .login 2>/dev/null || true)
  read -rp "GitHub username${default_user:+ [$default_user]}: " GH_USER_IN
  GH_USER_IN="${GH_USER_IN:-$default_user}"
  [[ -n $GH_USER_IN ]] || { echo "Username is required." >&2; exit 1; }

  read -rsp "Discord webhook URL (input hidden): " WEBHOOK_IN
  echo
  if [[ ! $WEBHOOK_IN =~ ^https://(discord|discordapp)\.com/api/webhooks/[0-9]+/.+ ]]; then
    echo "That doesn't look like a Discord webhook URL." >&2
    exit 1
  fi

  read -rp "Check interval (systemd span, e.g. 1min, 5min) [1min]: " POLL_IN
  POLL_IN="${POLL_IN:-1min}"
  if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze timespan "$POLL_IN" >/dev/null 2>&1 || { echo "Invalid interval: $POLL_IN" >&2; exit 1; }
  elif [[ ! $POLL_IN =~ ^[0-9]+(s|sec|secs|second|seconds|min|mins|minute|minutes|h|hr|hour|hours|d|day|days)$ ]]; then
    echo "Invalid interval: $POLL_IN" >&2
    exit 1
  fi

  (
    umask 077
    {
      echo "GH_USER=$GH_USER_IN"
      echo "DISCORD_WEBHOOK_URL=$WEBHOOK_IN"
      echo "POLL_INTERVAL=$POLL_IN"
      echo
      echo "# Optional: only needed if the systemd service can't read gh's keyring token."
      echo "# Use a token with \`repo\` scope, and authorize it for each SSO org."
      echo "# GH_TOKEN=ghp_xxxxxxxxxxxxxxxxxxxx"
    } > "$ENV_FILE"
  )
  echo "Saved $ENV_FILE"
fi
chmod 600 "$ENV_FILE"

# Migrate older env files that predate POLL_INTERVAL
if ! grep -q '^POLL_INTERVAL=' "$ENV_FILE"; then
  echo "POLL_INTERVAL=1min" >> "$ENV_FILE"
  echo "Added default POLL_INTERVAL=1min to $ENV_FILE"
fi

POLL_INTERVAL=$(grep '^POLL_INTERVAL=' "$ENV_FILE" | tail -n1 | cut -d= -f2-)
if command -v systemd-analyze >/dev/null 2>&1; then
  systemd-analyze timespan "$POLL_INTERVAL" >/dev/null 2>&1 || { echo "Invalid POLL_INTERVAL in $ENV_FILE: $POLL_INTERVAL" >&2; exit 1; }
elif [[ ! $POLL_INTERVAL =~ ^[0-9]+(s|sec|secs|second|seconds|min|mins|minute|minutes|h|hr|hour|hours|d|day|days)$ ]]; then
  echo "Invalid POLL_INTERVAL in $ENV_FILE: $POLL_INTERVAL" >&2
  exit 1
fi

# --- systemd -----------------------------------------------------------------
install -m 644 "$SRC/systemd/pr-merge-notify.service" "$UNIT_DIR/"
# Render timer from env (systemd timers can't read EnvironmentFile)
{
  echo "[Unit]"
  echo "Description=Check for merged PRs every $POLL_INTERVAL"
  echo
  echo "[Timer]"
  echo "OnBootSec=1min"
  echo "OnUnitActiveSec=$POLL_INTERVAL"
  echo
  echo "[Install]"
  echo "WantedBy=timers.target"
} > "$UNIT_DIR/pr-merge-notify.timer"
chmod 644 "$UNIT_DIR/pr-merge-notify.timer"
systemctl --user daemon-reload

if ! grep -q '^GH_TOKEN=' "$ENV_FILE" && ! gh auth status >/dev/null 2>&1; then
  echo "gh is not logged in. Run 'gh auth login' (or set GH_TOKEN in $ENV_FILE), then re-run." >&2
  exit 1
fi

systemctl --user enable --now pr-merge-notify.timer
echo "Installed. Timer status:"
systemctl --user list-timers pr-merge-notify.timer --no-pager
