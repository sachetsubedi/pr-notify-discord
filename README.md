# pr-merge-notify

Get a Discord notification whenever a PR you authored is merged — in any org or repo.

A small Bash poller that runs from your own machine every minute via a systemd
user timer. No GitHub App, no webhooks, no access to the target repos required.
It just uses the GitHub search API as *you* (`gh`), and posts a rich embed to
your Discord webhook.

## Features

- Notifies on merges across all repos/orgs you contribute to
- Rich Discord embed: PR title, repo, branch, diff stats, merger, timestamp
- No resident process — one-shot systemd service + timer
- Duplicate-safe: `seen` log + 30 min overlap window for search-index lag
- Failure-safe: time window only advances when all posts succeed
- Discord rate-limit (`429`) aware with retry
- Private by default: config file created with mode `600`

## How it works

1. Every minute, `pr-merge-notify.service` runs `bin/pr-merge-notify.sh`.
2. The script queries GitHub:
   `is:pr is:merged author:$GH_USER merged:>=$SINCE`
3. For each new hit it fetches `repos/{repo}/pulls/{num}`, builds a Discord
   embed payload with `jq`, and `POST`s it to `DISCORD_WEBHOOK_URL`.
4. Posted PRs (`owner/repo#number`) are appended to `state/seen`.
   `state/since` is updated only if every post succeeded, so failures retry
   on the next run.

First run only initializes `state/since` — it does not backfill old PRs, so
your channel won't get flooded.

## Requirements

- Linux with `systemd` (user timers)
- `gh` (authenticated — see below), `jq`, `curl`, GNU `date`

On Debian/Ubuntu:

```bash
sudo apt install gh jq curl
gh auth login
```

Verify:

```bash
gh auth status
```

## Install

```bash
git clone <your-repo-url> pr-merge-notify
cd pr-merge-notify
./install.sh
```

On first run `install.sh` will:

1. Copy files to `~/.local/share/pr-merge-notify/`
2. Prompt for your GitHub username (defaults to `gh api user --jq .login`)
3. Prompt for your Discord webhook URL (input hidden, validated)
4. Write them to `~/.local/share/pr-merge-notify/config/pr-merge-notify.env`
   with mode `600`
5. Install the systemd units and enable the timer

Re-running `./install.sh` keeps existing settings. To change them later, edit
the env file directly:

```bash
$EDITOR ~/.local/share/pr-merge-notify/config/pr-merge-notify.env
./install.sh
```

If run without a TTY (e.g. SSH pipe), it creates the env file from the
template and exits — edit it, then re-run `./install.sh`.

### Discord webhook

1. Discord channel → *Edit Channel → Integrations → Webhooks → New Webhook*
2. Copy the URL — it looks like
   `https://discord.com/api/webhooks/1234567890/AbCdEf...`
3. Paste it when prompted. Keep it secret — anyone with the URL can post to
   your channel.

### `gh` authentication

Normally the script reuses your existing `gh` login (keyring / `~/.config/gh`).

If the systemd service can't read your keyring token, set a fallback in the
env file instead:

```env
GH_TOKEN=ghp_xxxxxxxxxxxxxxxxxxxx
```

Use a classic token with `repo` scope, and for each SSO org click
*Authorize* / *SSO*. Then re-run `./install.sh`.

## Configuration

Env file: `~/.local/share/pr-merge-notify/config/pr-merge-notify.env` (mode `600`)

| Variable | Required | Description |
|---|---|---|
| `GH_USER` | yes | GitHub username to watch (`author:GH_USER`) |
| `DISCORD_WEBHOOK_URL` | yes | Discord webhook URL |
| `POLL_INTERVAL` | no | Check interval, any systemd span (default `1min`). Re-run `./install.sh` after changing. |
| `GH_TOKEN` | no | Fallback PAT, only if `gh auth` isn't visible to systemd |

Template with comments: `config/pr-merge-notify.env.example`.

## Usage

```bash
# timer status / next run
systemctl --user list-timers pr-merge-notify.timer

# run a check right now
systemctl --user start pr-merge-notify.service

# logs from the last runs
journalctl --user -u pr-merge-notify.service -e

# state files
cat ~/.local/share/pr-merge-notify/state/since
cat ~/.local/share/pr-merge-notify/state/seen
```

Check interval is 1 minute by default, defined by `POLL_INTERVAL` in the env
file. Systemd timers can't read env files directly, so `./install.sh`
renders `~/.config/systemd/user/pr-merge-notify.timer` from it
(`OnUnitActiveSec=$POLL_INTERVAL`). To change the cadence:

```bash
# edit ~/.local/share/pr-merge-notify/config/pr-merge-notify.env:
# POLL_INTERVAL=5min
./install.sh
```

### Re-test with an old PR

```bash
systemctl --user stop pr-merge-notify.timer

cd ~/.local/share/pr-merge-notify/state
echo 2026-09-01T00:00:00Z > since
: > seen

~/.local/share/pr-merge-notify/bin/pr-merge-notify.sh
```

## Project layout

Source repo:

```text
pr-merge-notify/
├── bin/pr-merge-notify.sh              # poller + Discord poster
├── config/pr-merge-notify.env.example  # config template
├── systemd/
│   ├── pr-merge-notify.service         # one-shot service
│   └── pr-merge-notify.timer           # every minute
├── install.sh
├── uninstall.sh
└── README.md
```

After install:

```text
~/.local/share/pr-merge-notify/
├── bin/pr-merge-notify.sh
├── config/
│   ├── pr-merge-notify.env             # your settings (600)
│   └── pr-merge-notify.env.example
└── state/
    ├── since                          # last successful check (UTC)
    └── seen                           # posted PRs, last 500 lines

~/.config/systemd/user/
├── pr-merge-notify.service
└── pr-merge-notify.timer
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Missing dependency: ...` | Install `gh`, `jq`, `curl`, `systemd` |
| `gh is not logged in` | Run `gh auth login`, or set `GH_TOKEN` in the env file |
| No notifications, no errors | Check `journalctl --user -u pr-merge-notify.service -e` and `list-timers`; run the service manually once |
| `Discord returned HTTP 4xx` | Webhook URL revoked/rotated — create a new one and update the env file |
| `That doesn't look like a Discord webhook URL` | Must match `https://(discord\|discordapp).com/api/webhooks/<id>/<token>` |
| Script works manually but not via timer | Keyring not unlocked for user services — set `GH_TOKEN` in the env file |
| Missing a merge | GitHub search index can lag a few minutes; the 30 min overlap + `seen` file covers this on the next run |

## Uninstall

```bash
./uninstall.sh            # remove timer/service, keep config + state
./uninstall.sh --purge    # remove everything, including ~/.local/share/pr-merge-notify
```

## Notes & limitations

- Linux + systemd user session required (no macOS `launchd` / Windows support).
- Polls `search/issues` with `per_page=50`, sorted by `updated` — more than
  50 merges in one 1-min window will spill into the next run(s).
- Discord embed description is truncated to 300 chars, title to 256 chars.
- `state/seen` keeps the last 500 entries.
- Keep `pr-merge-notify.env` and your webhook URL private.

## License

MIT — see [LICENSE](LICENSE).
