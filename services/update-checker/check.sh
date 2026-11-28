# Usage: update-checker RELEASES_FILE HOSTNAME
# Each line of RELEASES_FILE is "name<TAB>owner/repo<TAB>deployed tag". Posts to
# Slack when a repo's latest GitHub release isn't the deployed one: once when it
# comes out, then again every week until the pin is bumped.

releases=$1
state=$STATE_DIRECTORY
host=$2

# curl reads the webhook URL from a private file instead of its arguments, so it
# never shows up in the process list
umask 077
curl_config=$(mktemp)
trap 'rm -f "$curl_config"' EXIT
printf 'url = "%s"\n' "$(tr -d '[:space:]' < "$CREDENTIALS_DIRECTORY/slack-webhook")" > "$curl_config"

status=0
while IFS=$'\t' read -r name repo current; do
  if ! latest=$(curl -fsS --max-time 30 -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/$repo/releases/latest" | jq -er .tag_name); then
    echo "couldn't get the latest $name release" >&2
    status=1
    continue
  fi

  if [ "$latest" = "$current" ]; then
    rm -f "$state/$name"
    continue
  fi

  # already said so for this release in the last week
  if [ "$(cat "$state/$name" 2>/dev/null || true)" = "$latest" ] \
    && [ -n "$(find "$state/$name" -mtime -7)" ]; then
    continue
  fi

  text="$name $latest is out; $host runs $current. https://github.com/$repo/releases/tag/$latest"
  if jq -n --arg text "$text" '{text: $text}' \
    | curl -fsS --max-time 30 -K "$curl_config" -H 'Content-Type: application/json' --data-binary @- >/dev/null; then
    printf '%s\n' "$latest" > "$state/$name"
    echo "$text"
  else
    echo "couldn't post to Slack about $name $latest" >&2
    status=1
  fi
done < "$releases"

exit "$status"
