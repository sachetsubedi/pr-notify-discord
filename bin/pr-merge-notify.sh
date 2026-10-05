#!/usr/bin/env bash
# Posts a Discord embed for every PR you authored that got merged (any org/repo).
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$APP_DIR/config/pr-merge-notify.env"
STATE_DIR="$APP_DIR/state"
SEEN="$STATE_DIR/seen"
SINCE_FILE="$STATE_DIR/since"

# Under systemd the env file is injected; for manual runs, load it here.
if [[ -z ${GH_USER:-} || -z ${DISCORD_WEBHOOK_URL:-} ]] && [[ -f $ENV_FILE ]]; then
  set -a; . "$ENV_FILE"; set +a
fi
GH_USER="${GH_USER:?set GH_USER in $ENV_FILE}"
WEBHOOK="${DISCORD_WEBHOOK_URL:?set DISCORD_WEBHOOK_URL in $ENV_FILE}"

mkdir -p "$STATE_DIR"
touch "$SEEN"
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# First run: just record the time so old PRs don't flood the channel
if [[ ! -f $SINCE_FILE ]]; then
  echo "$NOW" > "$SINCE_FILE"
  echo "Initialized."
  exit 0
fi

# 30 min overlap covers search-index lag; the seen-list prevents duplicates
SINCE=$(date -u -d "$(cat "$SINCE_FILE") - 30 minutes" +%Y-%m-%dT%H:%M:%SZ)

post() {
  local payload=$1 code resp
  resp=$(mktemp)
  for _ in 1 2 3; do
    code=$(curl -sS -o "$resp" -w '%{http_code}' \
      -H 'Content-Type: application/json' -d "$payload" "$WEBHOOK") || { rm -f "$resp"; return 1; }
    case $code in
      2??) rm -f "$resp"; return 0 ;;
      429) sleep "$(jq -r '(.retry_after // 2) | ceil' "$resp")" ;;
      *)   echo "Discord returned HTTP $code: $(cat "$resp")" >&2; rm -f "$resp"; return 1 ;;
    esac
  done
  rm -f "$resp"; return 1
}

build_payload() {
  jq -n --argjson pr "$1" --arg repo "$2" '
    def trunc(n): if length > n then .[0:n-1] + "…" else . end;
    (($pr.body // "") | gsub("\r"; "") | trunc(300)) as $desc
    | {
        username: "GitHub",
        avatar_url: "https://github.githubassets.com/images/modules/logos_page/GitHub-Mark.png",
        embeds: [
          ({
            title: ("✅ PR #\($pr.number) merged: \($pr.title)" | trunc(256)),
            url: $pr.html_url,
            color: 9000933,
            author: {
              name: $pr.user.login,
              url: $pr.user.html_url,
              icon_url: $pr.user.avatar_url
            },
            thumbnail: { url: $pr.user.avatar_url },
            fields: [
              { name: "Repository", value: "[\($repo)](https://github.com/\($repo))", inline: true },
              { name: "Branch", value: "`\($pr.head.ref) → \($pr.base.ref)`", inline: true },
              { name: "Changes",
                value: "+\($pr.additions) −\($pr.deletions) · \($pr.changed_files) \(if $pr.changed_files == 1 then "file" else "files" end) · \($pr.commits) \(if $pr.commits == 1 then "commit" else "commits" end)",
                inline: true }
            ],
            footer: {
              text: "Merged by \($pr.merged_by.login // "unknown")",
              icon_url: ($pr.merged_by.avatar_url // $pr.user.avatar_url)
            },
            timestamp: $pr.merged_at
          } | if $desc != "" then .description = $desc else . end)
        ]
      }'
}

results=$(gh api -X GET search/issues \
  -f q="is:pr is:merged author:$GH_USER merged:>=$SINCE" \
  -f sort=updated -f per_page=50 \
  --jq '.items[] | "\(.repository_url)\t\(.number)"')

failed=0
while IFS=$'\t' read -r repo_url num; do
  [[ -z ${num:-} ]] && continue
  repo=${repo_url#https://api.github.com/repos/}
  key="$repo#$num"
  grep -qxF "$key" "$SEEN" && continue

  pr=$(gh api "repos/$repo/pulls/$num") || { failed=1; continue; }
  payload=$(build_payload "$pr" "$repo")

  if post "$payload"; then
    echo "$key" >> "$SEEN"
  else
    failed=1
  fi
done <<< "$results"

# Only advance the window if everything posted; failures retry next run
if [[ $failed -eq 0 ]]; then
  echo "$NOW" > "$SINCE_FILE"
fi
tail -n 500 "$SEEN" > "$SEEN.tmp" && mv "$SEEN.tmp" "$SEEN"
