# shellcheck shell=bash
# Functions that read docker / compose state. Nothing here changes anything.

PROJECT_LABEL="com.docker.compose.project"
WORKSPACE_LABELS=(dcc.workspace devcontainer.local_folder)

# Add -p to every compose call (without it the project name becomes the compose file's directory name,
# and all workspaces collide in the same project)
compose() {
  docker compose -p "$COMPOSE_PROJECT_NAME" "$@"
}

# $1: service, $2: extra docker ps options (-a to include stopped)
container_id() {
  docker ps -q ${2:+"$2"} \
    --filter "label=$PROJECT_LABEL=$COMPOSE_PROJECT_NAME" \
    --filter "label=com.docker.compose.service=$1" \
    | head -n 1
}

# $1: container id, $2: label
label_of() {
  docker inspect --format "{{index .Config.Labels \"$2\"}}" "$1"
}

# Label of the agent container (including stopped). Fails if there is no container
agent_label() {
  local id
  id="$(container_id agent -a)"
  [ -n "$id" ] || return 1
  label_of "$id" "$1"
}

# Signing key (fingerprint) the running gpg-signer pinned at startup. Empty if no sidecar / no key
signer_signing_key() {
  local signer
  signer="$(container_id gpg-signer)"
  [ -n "$signer" ] || return 0
  docker exec "$signer" cat /run/signing-key 2>/dev/null || true
}

# Service names of the compose project (comma-separated). $1: -a for existing containers only
project_services() {
  if [ "${1:-}" = -a ]; then
    compose ps -a --services 2>/dev/null
  else
    compose "${COMPOSE_FILES[@]}" config --services 2>/dev/null
  fi | paste -sd, - | sed 's/,/, /g'
}

# Turns what up will do into a predicate from the agent container's state: creating / starting / running
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

# Agent containers with a workspace label (created by either dcc or the devcontainer CLI). $@: extra docker ps options
workspace_container_ids() {
  local label
  for label in "${WORKSPACE_LABELS[@]}"; do
    docker ps -q "$@" --filter "label=$label"
  done | awk '!seen[$0]++'
}

# Template expression equivalent to {{or (.Label "dcc.workspace") (.Label "devcontainer.local_folder")}}
workspace_template() {
  local fn="$1" label out=""
  for label in "${WORKSPACE_LABELS[@]}"; do
    out="$out ($fn \"$label\")"
  done
  printf '{{or%s}}' "$out"
}
