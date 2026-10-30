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

uri="${DCC_GPG_SIGN_URI:?gpg-sign-client: DCC_GPG_SIGN_URI is not set (gpg module not enabled)}"
resp="$(mktemp)"
trap 'rm -f "$resp"' EXIT

if ! http="$(curl -sS -o "$resp" -w '%{http_code}' --max-time 60 \
    -H 'Content-Type: application/octet-stream' --data-binary @- "$uri")"; then
  echo "gpg-sign-client: cannot reach the gpg-signer sidecar" >&2
  exit 2
fi

jq -j '.status // empty' "$resp" >&2

if [ "$http" != "200" ]; then
  jq -r '.message // empty' "$resp" >&2
  echo "gpg-sign-client: signing failed (HTTP $http)" >&2
  exit 2
fi

jq -j '.signature' "$resp"
