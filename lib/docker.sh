# shellcheck shell=bash
# docker / compose の状態を読む関数。ここにあるものは何も変更しない。

PROJECT_LABEL="com.docker.compose.project"
WORKSPACE_LABELS=(dcc.workspace devcontainer.local_folder)

# すべての compose 呼び出しに -p を付ける (無いと project 名が compose ファイルのディレクトリ名になり、
# 全ワークスペースが同じプロジェクトに衝突する)
compose() {
  docker compose -p "$COMPOSE_PROJECT_NAME" "$@"
}

# $1: service、$2: docker ps の追加オプション (-a で停止中も含む)
container_id() {
  docker ps -q ${2:+"$2"} \
    --filter "label=$PROJECT_LABEL=$COMPOSE_PROJECT_NAME" \
    --filter "label=com.docker.compose.service=$1" \
    | head -n 1
}

# $1: container id、$2: label
label_of() {
  docker inspect --format "{{index .Config.Labels \"$2\"}}" "$1"
}

# 本体コンテナ (停止中も含む) のラベル。コンテナが無ければ失敗
agent_label() {
  local id
  id="$(container_id agent -a)"
  [ -n "$id" ] || return 1
  label_of "$id" "$1"
}

# 実行中の gpg-signer が起動時に固定した署名鍵 (fingerprint)。sidecar が無い / 鍵が無いなら空
signer_signing_key() {
  local signer
  signer="$(container_id gpg-signer)"
  [ -n "$signer" ] || return 0
  docker exec "$signer" cat /run/signing-key 2>/dev/null || true
}

# compose プロジェクトのサービス名 (カンマ区切り)。$1: 既存コンテナだけなら -a
project_services() {
  if [ "${1:-}" = -a ]; then
    compose ps -a --services 2>/dev/null
  else
    compose "${COMPOSE_FILES[@]}" config --services 2>/dev/null
  fi | paste -sd, - | sed 's/,/, /g'
}

# 本体コンテナの状態から up が何をするかを述語にする: creating / starting / running
up_verb() {
  local id
  id="$(container_id agent -a)"
  if [ -z "$id" ]; then
    printf creating
  elif [ "$(docker inspect --format '{{.State.Running}}' "$id")" = true ]; then
    printf running
  else
    printf starting
  fi
}

# ワークスペースラベルを持つ本体コンテナ (dcc / devcontainer CLI のどちらが作ったものも)。$@: docker ps の追加オプション
workspace_container_ids() {
  local label
  for label in "${WORKSPACE_LABELS[@]}"; do
    docker ps -q "$@" --filter "label=$label"
  done | awk '!seen[$0]++'
}

# {{or (.Label "dcc.workspace") (.Label "devcontainer.local_folder")}} 相当の template 式
workspace_template() {
  local fn="$1" label out=""
  for label in "${WORKSPACE_LABELS[@]}"; do
    out="$out ($fn \"$label\")"
  done
  printf '{{or%s}}' "$out"
}
