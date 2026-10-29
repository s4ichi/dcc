#!/usr/bin/env bash
# コンテナ作成後に root で一度だけ実行する部分 (cwd はワークスペース)。本体に sudo は無く、エージェントの
# プロセスからは root に上がれないので、dcc が `compose exec --user root` で呼ぶ。コンテナユーザーで行う
# 処理は postCreate.sh (この後に実行される)。devcontainer からの呼び方は docs/devcontainer.md。
#   postCreate-root.sh <user>
# 出力の規約は postCreate.sh と同じ ("<主語>: <述語>" / "warn: <主語>: <述語>")。
# root は capability を持たない (cap_drop ALL) ので、chown など CAP_* が要る処理はここにも書けない。
# shellcheck disable=SC2088  # 主語の "~/.claude" は表示用の文字列で、展開させない
set -euo pipefail

user="${1:?usage: postCreate-root.sh <user>}"
uid="$(id -u "$user")"
home="$(getent passwd "$user" | cut -d: -f6)"

has_cred() {
  case ",${DCC_CREDS:-}," in *",$1,"*) return 0 ;; esac
  return 1
}

# ~/.claude / ~/.codex が volume のとき (モジュール無効)、所有者がコンテナユーザーであることを確認する。
# イメージ側のディレクトリの所有者を空の volume が初回 mount で引き継ぐ前提なので、ここでは直さない
# (CAP_CHOWN が無い)。古いイメージで初回 mount した volume は root 所有のまま残るので、その場合は作り直す
check_volume_owner() {
  # $1: モジュール名、$2: ディレクトリ、$3: 表示用の volume 名
  has_cred "$1" && return 0
  [ "$(stat -c %u "$2")" = "$uid" ] && return 0
  echo "warn: $2: owned by uid $(stat -c %u "$2"), not $user; remove the volume ($3) and run 'dcc recreate' with the current image" >&2
  return 1
}
check_volume_owner claude "$home/.claude" "dcc-claude-home, or DCC_CLAUDE_HOME_VOLUME"
check_volume_owner codex "$home/.codex" "dcc-codex-home, or DCC_CODEX_HOME_VOLUME"

# ホストでインストールした plugin のメタデータはホストの絶対パスを含むため、
# ホストのホーム → コンテナのホームへ symlink して解決させる
if [ -n "${HOST_HOME:-}" ] && [ "${HOST_HOME}" != "${home}" ] && [ ! -e "${HOST_HOME}" ]; then
  mkdir -p "$(dirname "${HOST_HOME}")"
  ln -sfn "${home}" "${HOST_HOME}"
fi

# bind されたワークスペースはホスト uid のままなので safe.directory に登録する。
# ~/.gitconfig は ro なので system に書く
git config --system --add safe.directory "$(pwd)"

# gpg モジュール有効時: 署名を gpg-signer sidecar へ委譲する wrapper を gpg.program に登録する
# (主経路は compose の GIT_CONFIG_* 環境変数。ここは env が剥がれた場合の保険)。
# 検証用の公開鍵の import はコンテナユーザーの keyring なので postCreate.sh が行う
client=/usr/local/lib/dcc/gpg-sign-client.sh
if [ -x "$client" ]; then
  git config --system gpg.program "$client"
  echo "gpg: signing delegated to gpg-signer"
fi

# gh モジュール有効時: git の https 認証を gh-token sidecar の短命 token にする。
# gh auth setup-git は ~/.gitconfig (ro) に書こうとして失敗するので、system に登録する
client=/usr/local/lib/dcc/gh-token-client.sh
if [ -x "$client" ]; then
  host="${DCC_GH_HOST:-github.com}"
  git config --system --replace-all "credential.https://${host}.helper" "!${client} git-credential"
  echo "gh: token served by gh-token sidecar (gh and git over https://${host})"
fi
