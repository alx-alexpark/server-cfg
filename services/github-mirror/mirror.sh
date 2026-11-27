# Mirrors each GitHub repo given as "owner/name" into Forgejo, skipping ones that exist.
# FORGEJO_TOKEN (scopes: write:repository, read:user) and optionally GITHUB_TOKEN
# come from /var/lib/secrets/github-mirror.env.

: "${FORGEJO_TOKEN:?set FORGEJO_TOKEN in /var/lib/secrets/github-mirror.env}"
api=http://127.0.0.1:3000/api/v1

# Tokens reach curl and jq through a file descriptor, stdin or the environment,
# never as arguments: any local user can read a process's arguments in /proc.
# printf is a shell builtin, so it doesn't start a process of its own.
forgejo() {
  curl -sS -H @<(printf 'Authorization: token %s\n' "$FORGEJO_TOKEN") "$@"
}
github() {
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    curl -sSf -H @<(printf 'Authorization: Bearer %s\n' "$GITHUB_TOKEN") "$@"
  else
    curl -sSf "$@"
  fi
}

# Forgejo may still be starting after a reboot
for _ in $(seq 60); do
  curl -sf "$api/version" >/dev/null && break
  sleep 5
done

owner=$(forgejo -f "$api/user" | jq -r .login)
failed=0

for repo in "$@"; do
  name=${repo#*/}
  if [ "$(forgejo -o /dev/null -w '%{http_code}' "$api/repos/$owner/$name")" = 200 ]; then
    continue
  fi

  if ! info=$(github "https://api.github.com/repos/$repo"); then
    echo "can't read $repo on GitHub (private repos need GITHUB_TOKEN)"
    failed=1
    continue
  fi

  body=$(jq -n \
    --arg url "https://github.com/$repo" --arg name "$name" --arg owner "$owner" \
    --argjson info "$info" \
    '($ENV.GITHUB_TOKEN // "") as $token
     | {clone_addr: $url, repo_name: $name, repo_owner: $owner, service: "github",
        mirror: true, wiki: true, private: $info.private,
        description: ($info.description // "")}
     + (if $token != "" then {auth_token: $token} else {} end)')

  # the body holds the GitHub token, so it goes in on stdin
  code=$(forgejo -o /dev/null -w '%{http_code}' -X POST "$api/repos/migrate" \
    -H "Content-Type: application/json" --data-binary @- <<<"$body")
  if [ "$code" = 201 ]; then
    echo "mirrored $repo"
  else
    echo "failed to mirror $repo (HTTP $code)"
    failed=1
  fi
done

exit "$failed"
