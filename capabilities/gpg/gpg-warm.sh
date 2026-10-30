#!/usr/bin/env bash
# Run inside the sidecar to cache the signing key's passphrase in gpg-agent (the host's warm.sh calls it with docker exec -it).
# Exits silently if already cached; otherwise pinentry-curses appears once.
# Prints nothing on success (dcc reports the result in one line). If it cannot, prints the reason and fails.
set -euo pipefail

key="$(cat /run/signing-key 2>/dev/null || true)"
if [ -z "$key" ]; then
  echo "gpg-warm: no signing key exported (git user.signingkey unset on the host?)" >&2
  exit 1
fi

if ! gpg --list-secret-keys "$key" >/dev/null 2>&1; then
  echo "gpg-warm: signing key ${key} not in sidecar keyring (recreate the container)" >&2
  exit 1
fi

# Without a TTY, GPG_TTY="not a tty" reaches the agent and pinentry fails with a confusing error, so stop early
if ! GPG_TTY="$(tty)"; then
  echo "gpg-warm: no TTY; cannot prompt for passphrase. run from an interactive terminal" >&2
  exit 1
fi
export GPG_TTY

printf 'warm' | gpg --local-user "$key" --detach-sign --output /dev/null -
