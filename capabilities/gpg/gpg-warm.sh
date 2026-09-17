#!/usr/bin/env bash
# sidecar 内で実行し、署名鍵のパスフレーズを gpg-agent にキャッシュする (ホストの warm.sh が docker exec -it で呼ぶ)。
# キャッシュ済みなら無音で終了し、未キャッシュなら pinentry-curses が一度だけ出る。
# 成功時は何も出さない (dcc が結果を 1 行にする)。できない場合は理由を出して失敗する。
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

# TTY が無いと GPG_TTY="not a tty" が agent に渡り pinentry が紛らわしいエラーで失敗するため、先に止める
if ! GPG_TTY="$(tty)"; then
  echo "gpg-warm: no TTY; cannot prompt for passphrase. run from an interactive terminal" >&2
  exit 1
fi
export GPG_TTY

printf 'warm' | gpg --local-user "$key" --detach-sign --output /dev/null -
