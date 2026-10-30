# shellcheck shell=bash
# Settings. Reads ${DCC_CONFIG_DIR}/.env, defaults (same as template.jsonnet on the compose side),
# passes DCC_CONTAINER_ENV_* through, detects the personal Dockerfile.

# Reads ${DCC_CONFIG_DIR}/.env as bash and exports it. Shell environment variables take precedence
# (variables the file assigns that are already set are saved and restored after reading)
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

# Quotes a value for compose's env_file (dotenv format). Single quotes are uninterpreted, so use them by default;
# only when the value contains a single quote, use double quotes and escape \ " $
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

# Turns DCC_CONTAINER_ENV_<NAME>=value into the container environment variable NAME. compose cannot handle
# dynamic variable names, so write them to a dotenv-format temp file and pass it via env_file (DCC_CONTAINER_ENV_FILE).
# The temp file is removed when dcc exits (compose reads it only at container creation)
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

# If local/Dockerfile exists, the agent image is two-stage (repository Dockerfile -> base, personal on top)
personal_image_enabled() {
  [ -f "$LOCAL_DIR/Dockerfile" ]
}

# Reads .env and determines defaults (same as template.jsonnet on the compose side). dcc resolves CONFIG_DIR beforehand
load_config() {
  load_env_file "${DCC_ENV_FILE:-$CONFIG_DIR/.env}"
  CREDS_DEFAULT="${DCC_CREDS:-}"   # resolve_creds overwrites DCC_CREDS with its result, so capture the input here
  AGENT_DEFAULT="${DCC_AGENT:-claude}"

  # Arguments dcc prepends when launching the agent (whitespace-separated; quotes are not interpreted). Uses `-` expansion,
  # so setting an empty string disables the default. The codex default treats "the container is the sandbox" and
  # only removes Codex's own sandbox (bubblewrap; needs a user namespace and by default also cuts the network).
  # It doesn't touch the approval policy. It uses -c (config.toml override) rather than --sandbox so that the same
  # argument is not duplicated when the user adds `dcc exec -- --sandbox ...`. docs/codex.md
  local codex_args_default="-c sandbox_mode=danger-full-access -c check_for_update_on_startup=false"
  CLAUDE_ARGS="${DCC_CLAUDE_ARGS-}"
  CODEX_ARGS="${DCC_CODEX_ARGS-$codex_args_default}"

  CAPABILITIES_DIR="$CONFIG_DIR/capabilities"
  HOOKS_DIR="$CONFIG_DIR/lifecycle_hooks"
  LOCAL_DIR="${DCC_LOCAL_DIR:-$CONFIG_DIR/local}"
  GPG_EXPORT_DIR="${DCC_GPG_EXPORT_DIR:-$CAPABILITIES_DIR/gpg/gnupg-host}"
  BASE_IMAGE="${DCC_BASE_IMAGE:-dcc:base}"
  CLAUDE_HOME_VOLUME="${DCC_CLAUDE_HOME_VOLUME:-dcc-claude-home}"
  CODEX_HOME_VOLUME="${DCC_CODEX_HOME_VOLUME:-dcc-codex-home}"
  GH_HOME_VOLUME="${DCC_GH_HOME_VOLUME:-dcc-gh-home}"
  GH_HOST="${DCC_GH_HOST:-github.com}"
  GH_TOKEN_IMAGE=dcc-gh-token:local
  REMOTE_USER="${DCC_USER:-agent}"
  REMOTE_HOOKS_DIR=/usr/local/lib/dcc/hooks
  POSTCREATE_MARKER="/home/$REMOTE_USER/.dcc-postcreate-done"

  export_container_env
  if personal_image_enabled; then
    export DCC_BUILD_CONTEXT="$LOCAL_DIR"
    export DCC_DOCKERFILE="$LOCAL_DIR/Dockerfile"
  fi
}
