# shellcheck shell=bash
# Functions that change the compose project (COMPOSE_PROJECT_NAME). build / up / postCreate / gpg warm / gh login / stop / down.

# The FROM target of local/Dockerfile. The base-image overlay swaps agent's image / build to this repository's Dockerfile
# and runs `build agent`. The caller prepares COMPOSE_FILES. $@: docker compose build options
build_base_image() {
  local overlay="$CONFIG_DIR/docker-compose.base-image.yml"
  [ -f "$overlay" ] || die "$overlay not found (run 'make generate' in $CONFIG_DIR)"
  step image "building $BASE_IMAGE" "Dockerfile"
  run_step -t image compose "${COMPOSE_FILES[@]}" -f "$overlay" build "$@" agent
}

# Pass base and all overlays, and build every service that has a build (agent and module sidecars)
build_image() {
  compose_files "$ALL_CREDS"
  personal_image_enabled && build_base_image "$@"
  step image "building ${DCC_IMAGE:-dcc:local} and sidecars" \
    "$(personal_image_enabled && printf '%s/Dockerfile' "${LOCAL_DIR#"$CONFIG_DIR/"}" || printf Dockerfile)"
  run_step -t image compose "${COMPOSE_FILES[@]}" build "$@"
  done_step built "${SECONDS}s"
}

# When the claude / codex modules are not selected, ~/.claude / ~/.codex are fixed-name external volumes (shared by all workspaces;
# compose doesn't create external volumes and doesn't remove them even with down --volumes). base references both, so
# create the one for the unused agent too. $1: module name, $2: volume name, $3: path for display
ensure_home_volume() {
  has_cred "$1" && return 0
  docker volume inspect "$2" >/dev/null 2>&1 && return 0
  step volume "creating $2 for $3" "$1 module off"
  run_step volume docker volume create "$2"
}

# The gh module's state (refresh token) is also a fixed-name external volume. Shared by every workspace's gh-token sidecar;
# gh's refresh.lock (flock) serializes refreshes. docs/github.md
ensure_gh_volume() {
  docker volume inspect "$GH_HOME_VOLUME" >/dev/null 2>&1 && return 0
  step volume "creating $GH_HOME_VOLUME for gh credentials" "gh module"
  run_step volume docker volume create "$GH_HOME_VOLUME"
}

# Runs gh once in the gh-token sidecar's image (mounts the state volume; doesn't depend on the workspace's containers)
gh_sidecar_run() {
  local -a tty=(-i)
  [ -t 0 ] && [ -t 1 ] && tty+=(-t)
  docker run --rm "${tty[@]}" -v "$GH_HOME_VOLUME:/home/gh/.config/gh" --entrypoint gh "$GH_TOKEN_IMAGE" "$@"
}

# Prepares the token the gh-token sidecar hands out. --expiring requests a short-lived access token + refresh token
# (if the server doesn't support it gh falls back to a non-expiring token, so auth status shows the result at the end).
# The sidecar has no git, so git integration setup is skipped (--git-protocol ssh --skip-ssh-key). $@: extra args for gh auth login
gh_login() {
  ensure_gh_volume
  if ! docker image inspect "$GH_TOKEN_IMAGE" >/dev/null 2>&1; then
    step image "building $GH_TOKEN_IMAGE" "capabilities/gh/Dockerfile"
    run_step -t image docker build -t "$GH_TOKEN_IMAGE" "$CAPABILITIES_DIR/gh"
  fi
  step gh "logging in to $GH_HOST" "volume $GH_HOME_VOLUME"
  gh_sidecar_run auth login --hostname "$GH_HOST" --expiring --git-protocol ssh --skip-ssh-key "$@" \
    || { fail gh "login failed"; exit 1; }
  gh_sidecar_run auth status --hostname "$GH_HOST" || true
}

# If the agent image is missing compose builds it on up, but the base it uses as FROM is not built
ensure_base_image() {
  personal_image_enabled || return 0
  docker image inspect "$BASE_IMAGE" >/dev/null 2>&1 || build_base_image
}

# Caches the signing key's passphrase in the sidecar's gpg-agent (only on an interactive terminal).
# pinentry uses the TTY, so output is not buffered; only the result is turned into one line afterwards
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
    warn gpg "passphrase not cached; signed commits inside the container may fail" \
      "run '$CAPABILITIES_DIR/gpg/warm.sh -p $COMPOSE_PROJECT_NAME' to retry"
  fi
}

# Runs a hook inside the container. $1: user to run as, $2: script name (in lifecycle_hooks/), rest: arguments.
# Hooks print "<subject>: <predicate>" one per line, so relay turns them into ▸ lines as-is
run_hook() {
  local user="$1" script="$2"
  shift 2
  compose exec -T --user "$user" --workdir "$REMOTE_WORKSPACE" agent \
    bash "$REMOTE_HOOKS_DIR/$script" "$@" 2>&1 | relay \
    || { fail containers "$script failed (rerun with 'dcc up')"; exit 1; }
}

# Runs postCreate once inside the container (the marker is container-local; on failure it reruns on the next up).
# The agent container has no sudo, so dcc first runs the part that needs root (postCreate-root.sh) as root,
# then the rest (postCreate.sh) as the container user
run_post_create() {
  compose exec -T --user "$REMOTE_USER" agent test -e "$POSTCREATE_MARKER" && return 0
  run_hook root postCreate-root.sh "$REMOTE_USER"
  run_hook "$REMOTE_USER" postCreate.sh
  compose exec -T --user "$REMOTE_USER" agent touch "$POSTCREATE_MARKER"
}

# Existing containers are not recreated even if the config changed. Apply changes with dcc recreate.
# If images are all present, use --no-build (avoids compose's "No services to build" warning)
up_container() {
  # shellcheck disable=SC2086
  "$HOOKS_DIR/initialize.sh" $CREDS 2>&1 | relay \
    || { fail host "initialize failed"; exit 1; }
  if has_cred gpg && [ -n "$(host_signing_key)" ]; then
    step gpg "exported host keys" "signing key $(short_key "$(host_signing_key)")"
  fi
  check_drift
  compose_files "$CREDS"
  # shellcheck disable=SC2088  # "~/.claude" is a string for display and must not be expanded
  ensure_home_volume claude "$CLAUDE_HOME_VOLUME" "~/.claude"
  # shellcheck disable=SC2088
  ensure_home_volume codex "$CODEX_HOME_VOLUME" "~/.codex"
  if has_cred gh; then ensure_gh_volume; fi
  ensure_base_image
  local -a up_opts=(-d --no-recreate)
  if compose "${COMPOSE_FILES[@]}" config --images | xargs docker image inspect >/dev/null 2>&1; then
    up_opts+=(--no-build)
  fi
  step containers "$(up_verb) $(project_services)"
  run_step containers compose "${COMPOSE_FILES[@]}" up "${up_opts[@]}"
  run_post_create
}

# Arguments dcc prepends when launching $AGENT (DCC_CLAUDE_ARGS / DCC_CODEX_ARGS; load_config decides the defaults)
agent_args() {
  case "$AGENT" in
    claude) printf '%s' "$CLAUDE_ARGS" ;;
    codex) printf '%s' "$CODEX_ARGS" ;;
  esac
}

# Hands the terminal to the agent (claude / codex) here. Its exit code becomes dcc's exit code as-is.
# Default arguments are just split on whitespace (quotes are not interpreted). User arguments follow, each passed as-is
exec_agent() {
  local -a preset=()
  read -r -a preset <<<"$(agent_args)"
  done_step ready "${SECONDS}s"
  compose exec --user "$REMOTE_USER" --workdir "$REMOTE_WORKSPACE" agent \
    "$AGENT" "${preset[@]+"${preset[@]}"}" "$@"
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

# $1: also remove named volumes with --volumes
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
