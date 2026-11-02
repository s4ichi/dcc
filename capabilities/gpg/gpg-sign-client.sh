#!/usr/bin/env bash
# Wrapper that acts as git's gpg.program.
# Signing (`<program> --status-fd=2 -bsau <key>`) POSTs the payload to the gpg-signer sidecar and
# relays the status output of gpg in the sidecar to fd2 as is. The key is fixed on the sidecar side (<key> is ignored).
# Everything else (--verify etc.) is delegated to plain gpg.
set -euo pipefail

mode=passthrough
for a in "$@"; do
  case "$a" in
    -bsau) mode=sign ;;
  esac
done

if [ "$mode" != sign ]; then
  exec gpg "$@"
fi

# git (2.39 in the image) keeps gpg.program's stderr to itself and only says "gpg failed to sign the data",
# so the reason is also written to git's own stderr when git is the caller. docs/gpg.md
explain() {
  echo "$1" >&2
  if [ "$(cat "/proc/$PPID/comm" 2>/dev/null)" = git ]; then
    # Append: reopening a redirected file with > would truncate it
    { printf '%s\n' "$1" >>"/proc/$PPID/fd/2"; } 2>/dev/null || true
  fi
}

uri="${DCC_GPG_SIGN_URI:?gpg-sign-client: DCC_GPG_SIGN_URI is not set (gpg module not enabled)}"
resp="$(mktemp)"
trap 'rm -f "$resp"' EXIT

if ! http="$(curl -sS -o "$resp" -w '%{http_code}' --max-time 60 \
    -H 'Content-Type: application/octet-stream' --data-binary @- "$uri")"; then
  explain "gpg-sign-client: cannot reach the gpg-signer sidecar"
  exit 2
fi

jq -j '.status // empty' "$resp" >&2

if [ "$http" != "200" ]; then
  explain "gpg-sign-client: signing failed (HTTP $http): $(jq -r '.message // empty' "$resp")"
  exit 2
fi

jq -j '.signature' "$resp"
