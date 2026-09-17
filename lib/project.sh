# shellcheck shell=bash
# compose プロジェクト (COMPOSE_PROJECT_NAME) を変える関数。build / up / postCreate / gpg warm / stop / down。

# local/Dockerfile の FROM 先。base-image overlay で agent の image / build をこのリポジトリの Dockerfile に
# 差し替えて `build agent` する。COMPOSE_FILES は呼び出し側が用意する。$@: docker compose build のオプション
build_base_image() {
  local overlay="$CONFIG_DIR/docker-compose.base-image.yml"
  [ -f "$overlay" ] || die "$overlay not found (run 'make generate' in $CONFIG_DIR)"
  step image "building $BASE_IMAGE" "Dockerfile"
  run_step -t image compose "${COMPOSE_FILES[@]}" -f "$overlay" build "$@" agent
}

# base と全 overlay を渡し、build を持つ service (agent とモジュール sidecar) をすべてビルドする
build_image() {
  compose_files "$ALL_CREDS"
  personal_image_enabled && build_base_image "$@"
  step image "building ${DCC_IMAGE:-dcc:local} and sidecars" \
    "$(personal_image_enabled && printf '%s/Dockerfile' "${LOCAL_DIR#"$CONFIG_DIR/"}" || printf Dockerfile)"
  run_step -t image compose "${COMPOSE_FILES[@]}" build "$@"
  done_step built "${SECONDS}s"
}

# claude モジュールを外したときの ~/.claude は固定名の外部 volume (全ワークスペース共有。
# compose は external volume を作らず、down --volumes でも消さない)
ensure_claude_home_volume() {
  has_cred claude && return 0
  docker volume inspect "$CLAUDE_HOME_VOLUME" >/dev/null 2>&1 && return 0
  step volume "creating $CLAUDE_HOME_VOLUME for ~/.claude" "claude module off"
  run_step volume docker volume create "$CLAUDE_HOME_VOLUME"
}

# 本体イメージが無ければ compose が up 時に build するが、その FROM 先の base は作られない
ensure_base_image() {
  personal_image_enabled || return 0
  docker image inspect "$BASE_IMAGE" >/dev/null 2>&1 || build_base_image
}

# 署名鍵のパスフレーズを sidecar 内 gpg-agent にキャッシュする (対話ターミナルのときだけ)。
# pinentry が TTY を使うので出力はバッファせず、結果だけを後から 1 行にする
warm_gpg() {
  has_cred gpg || return 0
  [ -t 0 ] && [ -t 1 ] || return 0
  local key
  if [ -z "$(container_id gpg-signer)" ]; then
    warn gpg "gpg-signer is not running; passphrase not cached"
    return 0
  fi
  key="$(signer_signing_key)"
  if [ -z "$key" ]; then
    warn gpg "no signing key in gpg-signer; passphrase not cached" \
      "set git user.signingkey (or DCC_GPG_SIGNING_KEY) on the host and run '$(recreate_hint)'"
    return 0
  fi
  if "$CAPABILITIES_DIR/gpg/warm.sh" -p "$COMPOSE_PROJECT_NAME"; then
    step gpg "passphrase cached in gpg-signer" "signing key $(short_key "$key")"
  else
    warn gpg "passphrase not cached; signed commits inside claude may fail" \
      "run '$CAPABILITIES_DIR/gpg/warm.sh -p $COMPOSE_PROJECT_NAME' to retry"
  fi
}

# コンテナ内で postCreate を一度だけ実行する (マーカーはコンテナローカル。失敗時は次の up で再実行)。
# postCreate.sh は "<主語>: <述語>" を 1 行ずつ出すので relay でそのまま ▸ 行にする
run_post_create() {
  compose exec -T --user "$REMOTE_USER" agent test -e "$POSTCREATE_MARKER" && return 0
  compose exec -T --user "$REMOTE_USER" --workdir "$REMOTE_WORKSPACE" agent \
    bash "$REMOTE_HOOKS_DIR/postCreate.sh" 2>&1 | relay \
    || { fail containers "postCreate failed (rerun with 'dcc up')"; exit 1; }
  compose exec -T --user "$REMOTE_USER" agent touch "$POSTCREATE_MARKER"
}

# 既存コンテナは設定が変わっていても作り直さない。反映は dcc recreate。
# イメージが揃っていれば --no-build (compose の "No services to build" 警告を避ける)
up_container() {
  # shellcheck disable=SC2086
  "$HOOKS_DIR/initialize.sh" $CREDS 2>&1 | relay \
    || { fail host "initialize failed"; exit 1; }
  if has_cred gpg && [ -n "$(host_signing_key)" ]; then
    step gpg "exported host keys" "signing key $(short_key "$(host_signing_key)")"
  fi
  check_drift
  compose_files "$CREDS"
  ensure_claude_home_volume
  ensure_base_image
  local -a up_opts=(-d --no-recreate)
  if compose "${COMPOSE_FILES[@]}" config --images | xargs docker image inspect >/dev/null 2>&1; then
    up_opts+=(--no-build)
  fi
  step containers "$(up_verb) $(project_services)"
  run_step containers compose "${COMPOSE_FILES[@]}" up "${up_opts[@]}"
  run_post_create
}

# ここで端末を claude に渡す。claude の終了コードがそのまま dcc の終了コードになる
exec_claude() {
  done_step ready "${SECONDS}s"
  compose exec --user "$REMOTE_USER" --workdir "$REMOTE_WORKSPACE" agent claude "$@"
}

stop_containers() {
  local services
  services="$(project_services -a)"
  if [ -z "$services" ]; then
    step containers "none to stop" "$COMPOSE_PROJECT_NAME"
    return 0
  fi
  step containers "stopping $services" "$COMPOSE_PROJECT_NAME"
  run_step containers compose stop
}

# $1: --volumes で named volume も消す
clear_containers() {
  local services
  services="$(project_services -a)"
  if [ -z "$services" ]; then
    step containers "none to remove" "$COMPOSE_PROJECT_NAME"
  elif [ "${1:-}" = "--volumes" ]; then
    step containers "removing $services and volumes" "$COMPOSE_PROJECT_NAME"
  else
    step containers "removing $services" "$COMPOSE_PROJECT_NAME"
  fi
  if [ "${1:-}" = "--volumes" ]; then
    run_step containers compose down --remove-orphans --volumes
  else
    run_step containers compose down --remove-orphans
  fi
  local remaining
  remaining="$(docker ps -aq --filter "label=$PROJECT_LABEL=$COMPOSE_PROJECT_NAME" | wc -l | tr -d ' ')"
  [ "$remaining" = 0 ] || warn containers "$remaining still present in project $COMPOSE_PROJECT_NAME"
}
