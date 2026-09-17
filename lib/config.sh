# shellcheck shell=bash
# 設定。${DCC_CONFIG_DIR}/.env の読み込み、既定値 (compose 側 template.jsonnet と同じ)、
# DCC_CONTAINER_ENV_* の受け渡し、個人 Dockerfile の検出。

# ${DCC_CONFIG_DIR}/.env を bash として読んで export する。シェルの環境変数が優先
# (ファイルが代入する変数のうち既に設定済みのものを控えておき、読んだ後に戻す)
load_env_file() {
  local f="$1" key kv
  [ -f "$f" ] || return 0
  local -a keep=()
  while IFS= read -r key; do
    [ -n "${!key+x}" ] && keep+=("$key=${!key}")
  done < <(grep -oE '^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=' "$f" | sed -E 's/^[[:space:]]*(export[[:space:]]+)?//; s/=$//')
  set -a
  # shellcheck disable=SC1090
  . "$f"
  set +a
  for kv in "${keep[@]+"${keep[@]}"}"; do export "${kv?}"; done
}

# compose の env_file (dotenv 形式) 用に値を引用する。単一引用符内は無解釈なので基本はそれを使い、
# 値が単一引用符を含むときだけ二重引用符にして \ " $ をエスケープする
dotenv_quote() {
  local v="$1"
  if [[ "$v" != *"'"* ]]; then
    printf "'%s'" "$v"
  else
    v="${v//\\/\\\\}"
    v="${v//\"/\\\"}"
    v="${v//\$/\\\$}"
    printf '"%s"' "$v"
  fi
}

# DCC_CONTAINER_ENV_<NAME>=value をコンテナの環境変数 NAME にする。compose は動的な変数名を
# 扱えないので、dotenv 形式の一時ファイルに書き出して env_file (DCC_CONTAINER_ENV_FILE) で渡す。
# 一時ファイルは dcc の終了時に消す (compose が読むのはコンテナ作成時だけ)
export_container_env() {
  local var name
  local -a vars=()
  for var in $(compgen -e); do
    case "$var" in DCC_CONTAINER_ENV_FILE) ;; DCC_CONTAINER_ENV_?*) vars+=("$var") ;; esac
  done
  [ "${#vars[@]}" -gt 0 ] || return 0
  CONTAINER_ENV_FILE="$(mktemp "${TMPDIR:-/tmp}/dcc-env.XXXXXX")"
  trap 'rm -f "$CONTAINER_ENV_FILE"' EXIT
  for var in "${vars[@]}"; do
    name="${var#DCC_CONTAINER_ENV_}"
    printf '%s=%s\n' "$name" "$(dotenv_quote "${!var}")" >> "$CONTAINER_ENV_FILE"
  done
  export DCC_CONTAINER_ENV_FILE="$CONTAINER_ENV_FILE"
}

# local/Dockerfile があれば本体イメージは 2 段 (リポジトリの Dockerfile → base、その上に個人)
personal_image_enabled() {
  [ -f "$LOCAL_DIR/Dockerfile" ]
}

# .env を読み、既定値 (compose 側 template.jsonnet と同じ) を決める。CONFIG_DIR は dcc が先に解決している
load_config() {
  load_env_file "${DCC_ENV_FILE:-$CONFIG_DIR/.env}"
  CREDS_DEFAULT="${DCC_CREDS:-}"   # DCC_CREDS は resolve_creds が結果で上書きするので、入力はここで取る

  CAPABILITIES_DIR="$CONFIG_DIR/capabilities"
  HOOKS_DIR="$CONFIG_DIR/lifecycle_hooks"
  LOCAL_DIR="${DCC_LOCAL_DIR:-$CONFIG_DIR/local}"
  GPG_EXPORT_DIR="${DCC_GPG_EXPORT_DIR:-$CAPABILITIES_DIR/gpg/gnupg-host}"
  BASE_IMAGE="${DCC_BASE_IMAGE:-claude-devcontainer:base}"
  CLAUDE_HOME_VOLUME="${DCC_CLAUDE_HOME_VOLUME:-dcc-claude-home}"
  REMOTE_USER="${DCC_USER:-claude}"
  REMOTE_HOOKS_DIR=/usr/local/lib/claude-devcontainer/hooks
  POSTCREATE_MARKER="/home/$REMOTE_USER/.dcc-postcreate-done"

  export_container_env
  if personal_image_enabled; then
    export DCC_BUILD_CONTEXT="$LOCAL_DIR"
    export DCC_DOCKERFILE="$LOCAL_DIR/Dockerfile"
  fi
}
