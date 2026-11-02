# shellcheck shell=bash
# Shared by test/e2e/*.bats. Each file brings up its own workspace with the real dcc against a fake host: HOME is a
# temp directory holding dummy credentials (static AWS keys, a throwaway GnuPG key, an ssh key that is never
# registered anywhere, a gh token that is not a token), and images / volumes have e2e-only names, so the developer's
# real setup is neither read nor touched. docs/testing.md
#
# Settings (environment):
#   DCC_E2E_TMPDIR  where the fake hosts are made (default: $TMPDIR or /tmp). Must be a path the Docker daemon
#                   can bind at the same path (inside a dcc container: somewhere under /workspaces/<repo>)
#   DCC_E2E_DOCKER  "stub" replaces the Docker sidecar with an idle container, for places that cannot run nested
#                   dind (inside a dcc container). Tests that need the inner dockerd are skipped
#   DCC_E2E_UID     uid of the container user (default: the current uid, as on a Linux host; docs/customization.md)
#   DCC_E2E_ALL     1 runs the --all tests, which stop / remove every dcc workspace the daemon has (CI only)
#   DCC_E2E_KEEP    1 leaves containers, volumes and the fake host in place after each file

E2E_GPG_PASSPHRASE=e2e-passphrase

# $1: name of the file's workspace. Exports E2E_ROOT, HOME (fake), WS, PROJECT and the DCC_* that isolate the run
e2e_setup_file() {
  docker info >/dev/null 2>&1 || skip "Docker daemon not reachable"
  local tmp="${DCC_E2E_TMPDIR:-${TMPDIR:-/tmp}}" var
  mkdir -p "$tmp"
  E2E_ROOT="$(mktemp -d "$tmp/dcc-e2e-$1.XXXXXX")"
  # Docker CLI config (contexts, builders) stays the real one
  export DOCKER_CONFIG="${DOCKER_CONFIG:-$HOME/.docker}"
  export E2E_ROOT HOME="$E2E_ROOT/home"
  mkdir -p "$HOME"

  # Nothing from the developer's environment (inside a dcc container, the real module settings are there)
  for var in $(compgen -e | grep -E '^(DCC_[A-Z0-9_]+|AWS_[A-Z_]+|GH_[A-Z_]+|GITHUB_TOKEN|GNUPGHOME|GIT_CONFIG_[A-Z0-9_]+|TZ)$'); do
    case "$var" in DCC_E2E_*) ;; *) unset "$var" ;; esac
  done
  # dcc skips the repository's .env with DCC_ENV_FILE; compose would still read it as the project's .env
  export DCC_CONFIG_DIR="$REPO" DCC_ENV_FILE=/dev/null COMPOSE_DISABLE_ENV_FILE=1 NO_COLOR=1
  export DCC_IMAGE=dcc-e2e:local DCC_BASE_IMAGE=dcc-e2e:base DCC_UID="${DCC_E2E_UID:-$(id -u)}"
  export DCC_CLAUDE_HOME_VOLUME=dcc-e2e-claude-home DCC_CODEX_HOME_VOLUME=dcc-e2e-codex-home DCC_GH_HOME_VOLUME=dcc-e2e-gh-home
  export DCC_GPG_EXPORT_DIR="$E2E_ROOT/gnupg-host" DCC_SSH_DIR="$E2E_ROOT/ssh" DCC_LOCAL_DIR="$E2E_ROOT/local"
  # Not $HOME/.gnupg: with HOME faked that is gpg's default homedir, whose agent socket is the standard one, where a
  # systemd user gpg-agent of the real home may listen and would take the throwaway keys into the real keyring
  export DCC_GNUPG_DIR="$E2E_ROOT/gnupg"
  export DCC_COMPOSE_FILES=""
  if [ "${DCC_E2E_DOCKER:-}" = stub ]; then
    # Same image, volumes and sysctls, but dockerd never starts. HOST_HOME moves out of /workspaces: inside a dcc
    # container the fake host lives there, and postCreate-root.sh (root without capabilities) cannot create its
    # parent in /workspaces, which the container user owns
    cat >"$E2E_ROOT/stub-docker.yml" <<'EOF'
services:
  docker:
    entrypoint: ["tail", "-f", "/dev/null"]
    init: true
    privileged: false
  agent:
    environment:
      HOST_HOME: /tmp/dcc-e2e-host-home
EOF
    DCC_COMPOSE_FILES="$E2E_ROOT/stub-docker.yml"
  fi

  export WS="$E2E_ROOT/$1"
  mkdir -p "$WS"
  echo "hello from the host" >"$WS/hello.txt"
  git -C "$WS" init -q
  # The real project name, from dcc's own function
  PROJECT="$(DCC_WORKSPACE="$WS" bash -c '. "$DCC_CONFIG_DIR/dcc"; load_config; parse_args; resolve_workspace; echo "$COMPOSE_PROJECT_NAME"')"
  export PROJECT REMOTE_WS="/workspaces/$1"
  git config --file "$HOME/.gitconfig" user.name "dcc e2e"
  git config --file "$HOME/.gitconfig" user.email "e2e@example.invalid"
}

e2e_teardown_file() {
  [ -n "${E2E_ROOT:-}" ] || return 0
  if [ -n "${DCC_E2E_KEEP:-}" ]; then
    echo "# kept $E2E_ROOT (project $PROJECT)" >&3
    return 0
  fi
  "$REPO/dcc" clear "$WS" --volumes >/dev/null 2>&1 || true
  docker volume rm dcc-e2e-claude-home dcc-e2e-codex-home dcc-e2e-gh-home >/dev/null 2>&1 || true
  gpgconf --homedir "$DCC_GNUPG_DIR" --kill all 2>/dev/null || true
  # Containers may have left files owned by other uids; a leftover under TMPDIR is not worth failing for
  rm -rf -- "${E2E_ROOT:?}" 2>/dev/null || true
}

# Per test: when it failed, show what the containers were doing
e2e_teardown() {
  [ -z "${BATS_TEST_COMPLETED:-}" ] || return 0
  local id
  echo "--- containers of $PROJECT"
  docker ps -a --filter "label=com.docker.compose.project=$PROJECT" --format '{{.Names}}\t{{.Status}}'
  for id in $(docker ps -aq --filter "label=com.docker.compose.project=$PROJECT"); do
    echo "--- logs $(docker inspect --format '{{.Name}}' "$id")"
    docker logs --tail 30 "$id" 2>&1
  done
}

# Fills the fake host with everything the credential modules read. Exports GPG_FPR (the signing key, protected by
# $E2E_GPG_PASSPHRASE and selected through git user.signingkey) and GPG_FPR2 (a second key, for drift)
fake_host() {
  mkdir -p "$HOME/.claude" "$HOME/.codex" "$HOME/.aws/login/cache" "$DCC_SSH_DIR"
  echo '{"e2eMarker":"from-host"}' >"$HOME/.claude.json"
  echo "host" >"$HOME/.claude/host-file"
  printf 'model = "e2e-host-model"\n' >"$HOME/.codex/config.toml"
  # Temporary credentials, as `aws login` / SSO would give (the SDK's container provider requires a Token), served
  # offline by credential_process from the mounted login cache
  local expiration
  expiration="$(date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v+1H +%Y-%m-%dT%H:%M:%SZ)"
  printf '{"Version":1,"AccessKeyId":"ASIAE2EDUMMYKEY00000","SecretAccessKey":"e2e-dummy-secret-access-key","SessionToken":"e2e-dummy-session-token","Expiration":"%s"}\n' \
    "$expiration" >"$HOME/.aws/login/cache/e2e-process.json"
  cat >"$HOME/.aws/config" <<'EOF'
[default]
credential_process = cat /root/.aws/login/cache/e2e-process.json
region = us-east-1

[profile other]
credential_process = cat /root/.aws/login/cache/e2e-process.json
EOF
  GPG_FPR="$(new_gpg_key "$DCC_GNUPG_DIR" "dcc e2e <e2e@example.invalid>" "$E2E_GPG_PASSPHRASE")"
  GPG_FPR2="$(new_gpg_key "$DCC_GNUPG_DIR" "dcc e2e two <e2e-two@example.invalid>")"
  export GPG_FPR GPG_FPR2
  git config --file "$HOME/.gitconfig" user.signingkey "$GPG_FPR"
  ssh-keygen -q -t ed25519 -N '' -C dcc-e2e -f "$DCC_SSH_DIR/id_ed25519"
}

# Puts a gh login (a plain, non-expiring "token") into the gh state volume, the way dcc gh-login would leave it
seed_gh_volume() {
  docker image inspect dcc-gh-token:local >/dev/null 2>&1 || docker build -q -t dcc-gh-token:local "$REPO/capabilities/gh" >/dev/null
  printf 'github.com:\n    users:\n        e2e:\n            oauth_token: %s\n    git_protocol: https\n    oauth_token: %s\n    user: e2e\n' "$1" "$1" \
    | docker run --rm -i -v "$DCC_GH_HOME_VOLUME:/home/gh/.config/gh" --entrypoint sh dcc-gh-token:local \
      -c 'cat >/home/gh/.config/gh/hosts.yml'
}

# dcc <args>: the real CLI. Output (stdout + stderr) is what the tests assert on
dcc() {
  "$REPO/dcc" "$@"
}

service_id() {
  docker ps -q --filter "label=com.docker.compose.project=$PROJECT" --filter "label=com.docker.compose.service=$1"
}

# in_agent <cmd...>: runs in the agent container as the container user, in the workspace (like the agent does)
in_agent() {
  docker exec -i -u agent -w "$REMOTE_WS" "$(service_id agent)" "$@"
}

# in_agent_root <cmd...>: as root inside the agent container (what dcc does for postCreate-root.sh)
in_agent_root() {
  docker exec -i -u root -w "$REMOTE_WS" "$(service_id agent)" "$@"
}

require_dind() {
  [ "${DCC_E2E_DOCKER:-}" != stub ] || skip "Docker sidecar is stubbed (DCC_E2E_DOCKER=stub)"
}

# Mount sources of a container, one per line as "<type> <source> <destination>"
mounts_of() {
  docker inspect --format '{{range .Mounts}}{{.Type}} {{.Source}} {{.Destination}}{{println}}{{end}}' "$1"
}
