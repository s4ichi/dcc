#!/usr/bin/env bash
# ホストの GPG 公開鍵 / ownertrust と署名鍵の keygrip / fingerprint を DCC_GPG_EXPORT_DIR に書き出す。
# sidecar と本体はこの出力だけを読む (秘密鍵はここでは複製しない)。
#   pubkeys.asc / ownertrust.txt  秘密鍵を持つ全鍵の公開鍵 (検証にも使う)
#   keygrips.txt                  署名鍵の keygrip。sidecar はこれに列挙された鍵だけをコピーする
#   signing-key.txt               署名鍵の primary fingerprint
# 署名鍵は DCC_GPG_SIGNING_KEY、無ければ git config user.signingkey。
# gpg が無い / 秘密鍵が無い / 署名鍵未設定なら警告だけ出して終了する (署名なしで使える)。
# 出力は成功時は無し。警告は "warn: gpg: <message>" の 1 行 (dcc がそのまま ! 行にする)。
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

# fingerprint / keyid / email のいずれでもよい。末尾の '!' (subkey 固定) は落とす
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
