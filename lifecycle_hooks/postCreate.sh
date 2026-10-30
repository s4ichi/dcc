#!/usr/bin/env bash
# コンテナ作成後にコンテナユーザーで一度だけ実行する (cwd はワークスペース)。root が要る処理は
# postCreate-root.sh (dcc が先に root で実行する) に置く。本体に sudo は無い。
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
# - 無効: ~/.claude は全ワークスペース共有の空の volume (所有者はイメージから引き継がれ、postCreate-root.sh が
#   確認済み)。中身は Claude Code に任せる
if has_cred claude; then
  cp "${HOME}/.claude.json.host" "${HOME}/.claude.json"
  echo "~/.claude: shared with host"
else
  chmod 700 "${HOME}/.claude"
  echo "~/.claude: on volume dcc-claude-home (claude module off)"
fi

# ワークスペースを trust 済みにする。~/.claude.json はコンテナローカルなので、承認しても recreate で消えて
# 毎回確認が出る。コンテナ自体を境界とみなし、確認は省く (docs/claude-code.md)
claude_json="${HOME}/.claude.json"
[ -s "${claude_json}" ] || echo '{}' >"${claude_json}"
jq --arg ws "${PWD}" '.projects[$ws].hasTrustDialogAccepted = true' "${claude_json}" >"${claude_json}.tmp"
mv "${claude_json}.tmp" "${claude_json}"
echo "claude: ${PWD} trusted"

# ~/.codex も同じ (有効: ホストの rw bind、無効: 全ワークスペース共有の空の volume)。~/.codex には
# ~/.claude.json に当たる単独ファイルが無いのでコピーは要らない。Codex の実体は /opt/codex (イメージ) にあり、
# claude と違ってここでは更新しない (更新はイメージの rebuild)
if has_cred codex; then
  echo "~/.codex: shared with host"
else
  chmod 700 "${HOME}/.codex"
  echo "~/.codex: on volume dcc-codex-home (codex module off)"
fi

# gpg モジュール有効時: 検証用に公開鍵と ownertrust をコンテナユーザーの keyring へ import する
# (署名は postCreate-root.sh が登録した wrapper 経由で gpg-signer sidecar に委譲される)
setup_gnupg() {
  local export_dir="${HOME}/.gnupg-host"

  [ -s "${export_dir}/pubkeys.asc" ] || return 0

  gpg --batch --quiet --import "${export_dir}/pubkeys.asc" 2>/dev/null
  if [ -s "${export_dir}/ownertrust.txt" ]; then
    gpg --quiet --import-ownertrust "${export_dir}/ownertrust.txt" 2>/dev/null
  fi
  echo "gpg: public keys imported for verification"
}
setup_gnupg
