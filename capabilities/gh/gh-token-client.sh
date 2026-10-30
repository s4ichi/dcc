#!/usr/bin/env bash
# Agent-side client of the gh module. The token is fetched from the gh-token sidecar every time and never stored in the agent container. docs/github.md
#   When called as /usr/local/bin/gh: put it in GH_TOKEN and run /usr/bin/gh
#     (gh does not refresh GH_TOKEN, so fetch it again on every run)
#   `<this> git-credential get` (git credential helper): return the token for https on $DCC_GH_HOST
set -euo pipefail

real_gh=/usr/bin/gh

fetch_token() {
  local uri="${DCC_GH_TOKEN_URI:?gh-token-client: DCC_GH_TOKEN_URI is not set (gh module not enabled)}"
  local resp http
  resp="$(mktemp)"
  if ! http="$(curl -sS -o "$resp" -w '%{http_code}' --max-time 30 "$uri")"; then
    rm -f "$resp"
    echo "gh-token-client: cannot reach the gh-token sidecar" >&2
    return 1
  fi
  if [ "$http" != 200 ]; then
    echo "gh-token-client: $(cat "$resp")" >&2
    rm -f "$resp"
    return 1
  fi
  cat "$resp"
  rm -f "$resp"
}

# git passes key=value lines ending with an empty line. Answer only when host matches; otherwise return nothing
git_credential() {
  local line protocol="" host=""
  [ "${1:-}" = get ] || exit 0 # store / erase: nothing to store (the sidecar manages the token)
  while IFS= read -r line && [ -n "$line" ]; do
    case "$line" in
      protocol=*) protocol="${line#protocol=}" ;;
      host=*) host="${line#host=}" ;;
    esac
  done
  [ "$protocol" = https ] && [ "$host" = "${DCC_GH_HOST:-github.com}" ] || exit 0
  local token
  token="$(fetch_token)" || exit 0 # leave it to the next helper (or git's prompt if none)
  printf 'username=x-access-token\npassword=%s\n' "$token"
}

if [ "${1:-}" = git-credential ]; then
  shift
  git_credential "$@"
  exit 0
fi

# Auth state lives in the sidecar's volume and cannot be changed from gh in the agent container
case "${1:-} ${2:-}" in
  "auth login" | "auth logout" | "auth refresh" | "auth switch" | "auth setup-git")
    echo "gh-token-client: gh credentials are managed by the gh-token sidecar; run 'dcc gh-login' on the host" >&2
    exit 1
    ;;
esac

if token="$(fetch_token)"; then
  GH_TOKEN="$token" exec "$real_gh" "$@"
fi
exec "$real_gh" "$@"
