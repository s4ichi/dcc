#!/bin/sh
# gpg-signer sidecar の起動時にコンテナローカルの /root/.gnupg を組み立てる。
# - 公開鍵 / ownertrust: /gnupg-host (ホストの export、ro) から import
# - 秘密鍵: /host-keys (ro) から keygrips.txt に列挙された署名鍵だけをコピー
# - 署名鍵: signing-key.txt の値を /run/signing-key に固定 (鍵の変更は recreate)
set -eu

gnupg=/root/.gnupg
mkdir -p "$gnupg/private-keys-v1.d"
chmod 700 "$gnupg" "$gnupg/private-keys-v1.d"

# TTY なしの署名要求はキャッシュに依存するため、TTL はコンテナ寿命いっぱい (400 日)
cat > "$gnupg/gpg-agent.conf" <<'EOF'
pinentry-program /usr/bin/pinentry-curses
default-cache-ttl 34560000
max-cache-ttl 34560000
EOF

if [ -s /gnupg-host/pubkeys.asc ]; then
  gpg --batch --import /gnupg-host/pubkeys.asc
fi
if [ -s /gnupg-host/ownertrust.txt ]; then
  gpg --import-ownertrust /gnupg-host/ownertrust.txt
fi

if [ -s /gnupg-host/keygrips.txt ]; then
  while IFS= read -r grp; do
    [ -n "$grp" ] || continue
    if [ -f "/host-keys/$grp.key" ]; then
      cp "/host-keys/$grp.key" "$gnupg/private-keys-v1.d/"
      chmod 600 "$gnupg/private-keys-v1.d/$grp.key"
    else
      echo "gpg-signer: keygrip $grp not found in host keys" >&2
    fi
  done < /gnupg-host/keygrips.txt
else
  echo "gpg-signer: no keygrips exported; signing will be unavailable" >&2
fi

key=""
if [ -s /gnupg-host/signing-key.txt ]; then
  key="$(head -n 1 /gnupg-host/signing-key.txt | tr -d '[:space:]')"
fi
printf '%s' "$key" > /run/signing-key
DCC_GPG_SIGNING_KEY="$key"
export DCC_GPG_SIGNING_KEY

exec python3 /server.py
