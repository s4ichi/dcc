# shellcheck shell=bash
# コマンドライン。引数の解釈 (parse_args)、ワークスペースと compose プロジェクト名 (resolve_workspace)、
# 利用者向けの文面 (print_header / usage)。

# dcc が解釈するのは credential オプション、--agent、--all だけ。それ以外の --xxx と `--` 以降は ARGS に残し、
# コマンドへそのまま渡す (exec ならエージェント、build なら docker compose build)。先頭の非オプションが COMMAND。
# AGENT (実行するエージェント) もここで確定する: --agent > DCC_AGENT (load_config の AGENT_DEFAULT) > claude
parse_args() {
  local agent_request=""
  ALL=0
  CREDS_EXPLICIT=0              # --creds / --all-creds / --no-creds のどれかが指定された
  CREDS_REQUEST=""              # 指定されたモジュール (カンマ区切り。--creds の繰り返しは和集合)
  ARGS=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --agent)
        [ "$#" -ge 2 ] || die "--agent requires an argument"
        agent_request="$2"
        shift
        ;;
      --agent=*)
        agent_request="${1#--agent=}"
        ;;
      --creds)
        [ "$#" -ge 2 ] || die "--creds requires an argument"
        CREDS_REQUEST="${CREDS_REQUEST:+$CREDS_REQUEST,}$2"
        CREDS_EXPLICIT=1
        shift
        ;;
      --creds=*)
        CREDS_REQUEST="${CREDS_REQUEST:+$CREDS_REQUEST,}${1#--creds=}"
        CREDS_EXPLICIT=1
        ;;
      --all-creds)
        CREDS_REQUEST="$(list_all_creds | paste -sd, -)"
        CREDS_EXPLICIT=1
        ;;
      --no-creds)
        CREDS_REQUEST=""
        CREDS_EXPLICIT=1
        ;;
      --all) ALL=1 ;;
      --)
        shift
        ARGS+=("$@")
        break
        ;;
      *) ARGS+=("$1") ;;
    esac
    shift
  done
  COMMAND="${ARGS[0]:-default}"
  [ "${#ARGS[@]}" -eq 0 ] || ARGS=("${ARGS[@]:1}")
  AGENT="${agent_request:-${AGENT_DEFAULT:-claude}}"
  case "$AGENT" in
    claude|codex) ;;
    *) die "unknown agent '$AGENT' (available: claude codex)" ;;
  esac
}

# stdin の sha256 の先頭 8 桁 (macOS: shasum、Linux: sha256sum)
sha256_prefix() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | cut -c1-8
  else
    sha256sum | cut -c1-8
  fi
}

# dcc-<basename ([a-z0-9_-] のみ)>-<パスの sha256 先頭 8 桁>。同名ディレクトリ同士も衝突しない
project_name() {
  local base hash
  base="$(printf '%s' "$LOCAL_WORKSPACE_BASENAME" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')"
  hash="$(printf '%s' "$WORKSPACE" | sha256_prefix)"
  printf 'dcc-%s-%s' "$base" "$hash"
}

# ワークスペース: 先頭の引数がディレクトリならそれ → DCC_WORKSPACE → $PWD。
# LOCAL_WORKSPACE_* は workspace overlay が、COMPOSE_PROJECT_NAME は compose() が使う
resolve_workspace() {
  WORKSPACE="${DCC_WORKSPACE:-$PWD}"
  if [ "${#ARGS[@]}" -gt 0 ] && [ -d "${ARGS[0]}" ]; then
    WORKSPACE="${ARGS[0]}"
    ARGS=("${ARGS[@]:1}")
  fi
  WORKSPACE="$(cd "$WORKSPACE" && pwd)"
  export LOCAL_WORKSPACE_FOLDER="$WORKSPACE"
  LOCAL_WORKSPACE_BASENAME="$(basename "$WORKSPACE")"
  export LOCAL_WORKSPACE_BASENAME
  REMOTE_WORKSPACE="/workspaces/$LOCAL_WORKSPACE_BASENAME"
  COMPOSE_PROJECT_NAME="$(project_name)"
  export COMPOSE_PROJECT_NAME
}

# ヘッダーブロック。以降のログは 1 行 1 情報なので、毎回変わらない事実 (どこで・何を渡して・どのイメージで) はここにまとめる
print_header() {
  local name disabled="" image
  for name in $ALL_CREDS; do
    has_cred "$name" || disabled="${disabled:+$disabled }$name"
  done
  image="${DCC_IMAGE:-dcc:local}"
  personal_image_enabled && image="$image  $C_DIM(base + ${LOCAL_DIR#"$CONFIG_DIR/"}/Dockerfile)$C_RST"
  {
    printf '%sdcc  %s%s  %s%s%s\n' "$C_BOLD" "$LOCAL_WORKSPACE_BASENAME" "$C_RST" "$C_DIM" "$COMPOSE_PROJECT_NAME" "$C_RST"
    printf '     %s%-12s%s %s\n' "$C_DIM" workspace "$C_RST" "$WORKSPACE"
    case "$COMMAND" in
      default|exec) printf '     %s%-12s%s %s\n' "$C_DIM" agent "$C_RST" "$AGENT" ;;
    esac
    printf '     %s%-12s%s %s%s%s\n' "$C_DIM" credentials "$C_RST" "${CREDS:-(none)}" \
      "${disabled:+  $C_DIM(off: $disabled)$C_RST}" "$([ "$CREDS_SOURCE" = container ] && printf '  %s(existing container)%s' "$C_DIM" "$C_RST")"
    printf '     %s%-12s%s %s\n' "$C_DIM" image "$C_RST" "$image"
    echo
  } >&2
}

usage() {
  cat <<USAGE
Usage:
  dcc [command] [workspace] [options] [args...]

Commands:
  up                 Start or create the containers (agent + docker sidecar)
  exec [args]        Run the agent (claude or codex) inside the container (args are passed to it)
  stop [--all]       Stop the compose project (--all: every workspace)
  clear [--all] [--volumes]
                     Remove the compose project(s) (keep named volumes unless --volumes)
  recreate           Remove and recreate the container
  build [opts]       Build the agent and module sidecar images (e.g. dcc build --no-cache).
                     With \$DCC_LOCAL_DIR/Dockerfile present, the base image is built first,
                     then the personal one on top of it
  creds              Show available credential modules and the running container's selection
  list, ls           List containers across all workspaces
  inspect            Show container details across all workspaces
  help               Show this help

Default:
  dcc         Equivalent to: dcc up && dcc exec

Agent option (default / exec):
  --agent <name>     Agent to run: claude or codex (default: \$DCC_AGENT, or claude).
                     Both live in the same container; the choice is per invocation

Credential options (default / up / exec / recreate):
  --creds <a,b,...>  Enable credential modules (comma separated, repeatable)
  --all-creds        Enable every module
  --no-creds         Enable none
  Without any of these, an existing container keeps its own selection (modules only
  apply at creation); a new container gets \$DCC_CREDS, or none if unset

Environment (all optional; may also be put in \$DCC_CONFIG_DIR/.env):
  DCC_CREDS               Default for --creds (e.g. DCC_CREDS=gpg,ssh)
  DCC_AGENT               Default for --agent (claude or codex)
  DCC_CLAUDE_ARGS         Arguments dcc puts before yours when it runs claude (default: none)
  DCC_CODEX_ARGS          Same for codex. Default turns off Codex's own sandbox, as the container
                          is the sandbox: -c sandbox_mode=danger-full-access
                          -c check_for_update_on_startup=false. Set to empty to pass nothing
  DCC_VERBOSE             Set to 1 to stream compose / hook output (otherwise shown only on failure)
  DCC_CONFIG_DIR          Config directory (default: ~/.config/dcc)
  DCC_ENV_FILE            Env file to load (default: \$DCC_CONFIG_DIR/.env)
  DCC_WORKSPACE           Workspace path (default: \$PWD)
  DCC_LOCAL_DIR           Personal files dir (default: \$DCC_CONFIG_DIR/local, gitignored):
                          Dockerfile (layers on top of the base image), compose.yml (overlay)
  DCC_COMPOSE_FILES       Extra compose overlays, colon separated absolute paths
  DCC_USER / DCC_UID / DCC_GID / DCC_IMAGE / DCC_TZ / DCC_*_DIR / DCC_*_PORT ...
                          See .env.example in \$DCC_CONFIG_DIR for the full list
USAGE
}
