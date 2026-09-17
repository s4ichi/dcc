#!/usr/bin/env bash
# コンテナ作成後にコンテナ内で一度だけ実行する (cwd はワークスペース)。
# 出力は「コンテナがどうなったか」を "<主語>: <述語>" で 1 行ずつ (dcc がそのまま ▸ 行にする)。
# 警告は "warn: <主語>: <述語>"。毎回同じ結果になる処理 (safe.directory 等) は書かない。
# shellcheck disable=SC2088  # 主語の "~/.claude" は表示用の文字列で、展開させない
set -euo pipefail

has_cred() {
  case ",${DCC_CREDS:-}," in *",$1,"*) return 0 ;; esac
  return 1
}

# Claude Code を最新にする。結果はコンテナ層に残り、recreate で焼き込み版に戻る (そのときまたここで最新化する)。
# オフライン等で失敗しても焼き込み版で起動できるため警告に留める。
if claude update >/dev/null 2>&1; then
  echo "claude: updated to $(claude --version | awk '{print $1}')"
else
  echo "warn: claude: update failed (offline?); using $(claude --version | awk '{print $1}')" >&2
fi

# ~/.claude の初期化。
# - claude モジュール有効: ~/.claude はホストの rw bind。~/.claude.json は single-file bind だと
#   atomic write が EXDEV で失敗するため、ro で渡された初期値をコンテナローカルへコピーする
# - 無効: ~/.claude は全ワークスペース共有の空の volume。所有者だけ直し、中身は Claude Code に任せる
if has_cred claude; then
  cp "${HOME}/.claude.json.host" "${HOME}/.claude.json"
  echo "~/.claude: shared with host"
else
  sudo chown "$(id -u):$(id -g)" "${HOME}/.claude"
  chmod 700 "${HOME}/.claude"
  echo "~/.claude: on volume dcc-claude-home (claude module off)"
fi

# ~/.codex も同じ (有効: ホストの rw bind、無効: 全ワークスペース共有の空の volume)。~/.codex には
# ~/.claude.json に当たる単独ファイルが無いのでコピーは要らない。Codex の実体は /opt/codex (イメージ) にあり、
# claude と違ってここでは更新しない (更新はイメージの rebuild)
if has_cred codex; then
  echo "~/.codex: shared with host"
else
  sudo chown "$(id -u):$(id -g)" "${HOME}/.codex"
  chmod 700 "${HOME}/.codex"
  echo "~/.codex: on volume dcc-codex-home (codex module off)"
fi

# ホストでインストールした plugin のメタデータはホストの絶対パスを含むため、
# ホストのホーム → コンテナのホームへ symlink して解決させる
if [ -n "${HOST_HOME:-}" ] && [ "${HOST_HOME}" != "${HOME}" ] && [ ! -e "${HOST_HOME}" ]; then
  sudo mkdir -p "$(dirname "${HOST_HOME}")"
  sudo ln -sfn "${HOME}" "${HOST_HOME}"
fi

# bind されたワークスペースはホスト uid のままなので safe.directory に登録する。
# ~/.gitconfig は ro なので system に書く
sudo git config --system --add safe.directory "$(pwd)"

# gpg モジュール有効時: 検証用に公開鍵を import し、署名は gpg-signer sidecar へ委譲する wrapper を
# gpg.program に登録する (主経路は compose の GIT_CONFIG_* 環境変数。ここは env が剥がれた場合の保険)
setup_gnupg() {
  local export_dir="${HOME}/.gnupg-host"
  local client=/usr/local/lib/dcc/gpg-sign-client.sh

  [ -s "${export_dir}/pubkeys.asc" ] || return 0

  gpg --batch --quiet --import "${export_dir}/pubkeys.asc" 2>/dev/null
  if [ -s "${export_dir}/ownertrust.txt" ]; then
    gpg --quiet --import-ownertrust "${export_dir}/ownertrust.txt" 2>/dev/null
  fi

  if [ -x "$client" ]; then
    sudo git config --system gpg.program "$client"
    echo "gpg: signing delegated to gpg-signer"
  fi
}
setup_gnupg
