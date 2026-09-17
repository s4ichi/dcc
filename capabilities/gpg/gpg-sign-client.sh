#!/usr/bin/env bash
# git の gpg.program として動く wrapper。
# 署名 (`<program> --status-fd=2 -bsau <key>`) は payload を gpg-signer sidecar に POST し、
# sidecar 内の gpg の status 出力を fd2 へそのまま中継する。鍵は sidecar 側で固定 (<key> は使わない)。
# それ以外 (--verify 等) は素の gpg に委譲する。
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
