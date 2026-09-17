#!/usr/bin/env bash
# ホスト側の前処理。引数の credential モジュールごとに export と bind ソースの事前チェックを行う。
# dcc up と devcontainer の initializeCommand から呼ぶ:
#   initialize.sh gpg aws
# パスは compose と同じ DCC_* 環境変数 (同じ既定値) で解決する。
# 出力は成功時は無し。警告は "warn: <module>: <message>" の 1 行 (dcc がそのまま ! 行にする)。
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"

warn_missing() {
  # $1: パス、$2: モジュール名、$3: 補足
  # ソースが無い bind は compose のバージョンによってエラーになるか、空ディレクトリが自動で作られる
  [ -e "$1" ] || echo "warn: $2: $1 not found; the module mounts it, so 'up' may fail or leave an empty directory there${3:+ ($3)}" >&2
}

for module in "$@"; do
  case "$module" in
    claude)
      warn_missing "${DCC_CLAUDE_DIR:-$HOME/.claude}" claude
      warn_missing "${DCC_CLAUDE_JSON:-$HOME/.claude.json}" claude "start Claude Code on the host once"
      ;;
    codex)
      warn_missing "${DCC_CODEX_DIR:-$HOME/.codex}" codex "start Codex on the host once"
      ;;
    gpg)
      "$repo/capabilities/gpg/export-host-keys.sh"
      ;;
    aws)
      aws_dir="${DCC_AWS_DIR:-$HOME/.aws}"
      warn_missing "$aws_dir/config" aws
      warn_missing "$aws_dir/login/cache" aws "run 'aws login' on the host once"
      ;;
    ssh)
      warn_missing "${DCC_SSH_DIR:-$repo/capabilities/ssh/data}" ssh
      ;;
    gh)
      warn_missing "${DCC_GH_DIR:-$repo/capabilities/gh/data}" gh
      ;;
    *)
      echo "warn: $module: unknown module (ignored)" >&2
      ;;
  esac
done
