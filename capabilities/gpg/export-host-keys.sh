#!/usr/bin/env bash
# Write the host's GPG public keys / ownertrust and the signing key's keygrip / fingerprint to DCC_GPG_EXPORT_DIR.
# The sidecar and the agent container read only this output (private keys are not copied here).
#   pubkeys.asc / ownertrust.txt  public keys of all keys with a private key (also used for verification)
#   keygrips.txt                  keygrips of the signing key. The sidecar copies only the keys listed here
#   signing-key.txt               primary fingerprint of the signing key
# The signing key is DCC_GPG_SIGNING_KEY, or git config user.signingkey if unset.
# If gpg is missing / there is no private key / no signing key is set, print a warning and exit (usable without signing).
# No output on success. A warning is one line "warn: gpg: <message>" (dcc turns it into a ! line as is).
set -euo pipefail

out="${DCC_GPG_EXPORT_DIR:-$(cd "$(dirname "$0")" && pwd)/gnupg-host}"
export GNUPGHOME="${DCC_GNUPG_DIR:-${GNUPGHOME:-$HOME/.gnupg}}"

mkdir -p "$out"
chmod 700 "$out"
: > "$out/keygrips.txt"
: > "$out/signing-key.txt"

if ! command -v gpg >/dev/null 2>&1; then
  echo "warn: gpg: host gpg not found; keys not exported (signed commits unavailable)" >&2
  exit 0
fi

fprs="$(gpg --list-secret-keys --with-colons 2>/dev/null | awk -F: '$1=="fpr"{print $10}')"
if [ -z "$fprs" ]; then
  echo "warn: gpg: no secret keys on host; keys not exported" >&2
  exit 0
fi

printf '%s\n' "$fprs" | xargs gpg --export --armor > "$out/pubkeys.asc"
gpg --export-ownertrust > "$out/ownertrust.txt"

# May be a fingerprint / keyid / email. Drop a trailing '!' (subkey pinning)
key="${DCC_GPG_SIGNING_KEY:-$(git config --get user.signingkey || true)}"
key="${key%!}"
if [ -z "$key" ]; then
  echo "warn: gpg: no signing key (set DCC_GPG_SIGNING_KEY or git user.signingkey on the host); gpg-signer will refuse to sign" >&2
  exit 0
fi
if ! colons="$(gpg --list-secret-keys --with-keygrip --with-colons "$key" 2>/dev/null)"; then
  echo "warn: gpg: signing key '$key' not found in host keyring; gpg-signer will refuse to sign" >&2
  exit 0
fi
printf '%s\n' "$colons" | awk -F: '$1=="grp"{print $10}' > "$out/keygrips.txt"
fpr="$(printf '%s\n' "$colons" | awk -F: '$1=="fpr"{print $10; exit}')"
printf '%s\n' "$fpr" > "$out/signing-key.txt"

[ -d "$GNUPGHOME/private-keys-v1.d" ] \
  || echo "warn: gpg: $GNUPGHOME/private-keys-v1.d not found; the module mounts it, so 'up' may fail or leave an empty directory there" >&2
